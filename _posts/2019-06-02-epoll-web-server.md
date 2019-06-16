---
layout: post
title: Concurrent HTTP Server with Epoll
tags: [linux, epoll, c, http, concurrency]
author-id: kaleid-liner
excerpt_separator: <!--more-->
---

Several days ago, my Operating System class assigned a lab, [to write a concurrent http server](<https://github.com/OSH-2019/OSH-2019.github.io/tree/master/3>). I finally decide to complete this lab in C and using [**epoll**](<http://man7.org/linux/man-pages/man7/epoll.7.html>) to implement I/O multiplexing. It turns out that epoll is really hard to use, especially in multithreaded environments. So I write this post to document some pitfalls while using epoll. The source code of the HTTP Server can be found at [here](<https://github.com/kaleid-liner/epoll-web-server>). <!--more-->

The epoll API monitors multiple file descriptors to see if I/O is possible on any of them. To understand epoll, I recommend [this post](<https://medium.com/@copyconstruct/the-method-to-epolls-madness-d9d2d6378642>), a well-written article that explains low-level details of epoll thoroughly and differentiates between level-triggered and edge-triggered mode.

## Use thread pool

Before taking epoll into consideration, to improve performance and throughput of your web server, you have to utilize your multicore processor. Using `fork` requires little work. But it's better to use Posix Thread. And as creating a thread every time a request comes is not negligible, creating a thread pool while initializing the server is a sensible choice.

```c
for (int i = 0; i < THREAD_NUM; ++i) {
    if (pthread_create(&threads[i], NULL, thread, &targs) < 0) {
        fprintf(stderr, "error while creating %d thread\n", i);
        exit(1);
    }
}
```

Where `thread` is defined as `void *thread(void *args)`.  I will write on it later on.

But remember, just using thread pool perhaps won't mean a lot to your concurrency. Because as long as your thread num is set to a reasonable range, I mean, 2-3 times your processor num, if any task stucks in the thread, the thread poll will run out quickly. 

## Steps my server will go through

Before introducing how to use epoll, I will first give an overview of steps my server will take after planting epoll into it. It may help you to grasp the structure of my code. 

1. The main thread finish initializing work (e.g., configing network, listening on socket).

2. The main thread creates an epoll instance and adds the listen file descriptor to the interest list of the epoll instance (**Edge Triggered**).

3. The main thread creates `THREAD_NUM` threads (`epollfd` and `listenfd` will be passed as arguments). Then both the main thread and the child threads will serve as workers.

4. From now on is what `void *thread(void *args)` is responsible. All the workers call `epoll_wait` on the epoll instance. 

5. When any event is caught, the worker thread that gets it will do:

   1. Check if it's `listenfd`. If It is `listenfd`, then call `accept` on it and add `connfd` (return value of `accept`) to the interest list.

   2. Else it is a `connfd`. `read` on it. If the header transport is done (a blank new line detected), then respond to it. Else store the status at `event.data.ptr`.

      The status is defined as:

      ```c
      // src/main.h
      typedef struct HttpStatus {
          int connfd;     // connection file descriptor
          char *header;   // http header read, malloced with `MAX_HEADER` size
          size_t readn;   // number of bytes read
          FILE *file;     // file to send
          size_t left;    // number of bytes left to send
          req_status_t req_status; 
      } http_status_t;
      ```
   
      While `req_status_t` is defined as:
   
      ```c
      // src/main.h
      typedef enum REQUEST_STATUS {
          Reading,
          Writing,
          Ended
      } req_status_t;
      ```
   
      Next time when `epoll_wait` get events on this fd, the server will continue on the request.
   
   3. After complete reading, connfd will enter status `Writing`. If `sendfile` cause `EAGAIN`, and `left > 0` , it means that writing end is temporily unavailable. I have to save the status, `EPOLL_CTL_MOD` to change its trigger events to `EPOLLOUT | EPOLLET`. And continue the writing next time. 

## Epoll Usage

You'd better first read the [linux man page](<http://man7.org/linux/man-pages/man7/epoll.7.html>). But it's ok here to present a brief summary of epoll usage (and especially in multithreaded environment).

Epoll just requires you to use `epoll_create1`, `epoll_ctl`, `epoll_wait`api. `epoll_ctl` includes three kinds of action: `EPOLL_CTL_ADD`, `EPOLL_CTL_MOD`, `EPOLL_CTL_DEL`, which are self-explanatory.

 ```c
int epollfd = epoll_create1(0);
 ```

to create an epoll instance.

```c
struct epoll_event ev;
ev.events = EPOLLIN | EPOLLOUT | EPOLLET;
ev.data.fd = fd_to_monitor;

epoll_ctl(epollfd, EPOLL_CTL_ADD, fd_to_monitor, &ev);
```

to add the fd to interest list. Here `EPOLLET` means edge triggered mode. If you have read the doc or the post I mentioned above, you are familiar with it. `ev.data` is in fact a union. I will explain it later on.

```c
struct epoll_event *events = (struct epoll_event *)malloc(sizeof(struct epoll_event) * MAX_EVENTS);

int nfds = epoll_wait(epollfd, events, MAX_EVENTS, -1);

if (nfds <= 0) {
    perror("epoll_wait");
    continue;
}
for (int n = 0; n < nfds; ++n) {
    consume(events[n].data.fd);
}
```

to do what you want to do to the file descriptor.

### Multithread: `epoll_wait` is thread-safe, but...

It's absolutely ok to share an epoll file descriptor among several threads. Actually this is what epoll is designed as. If you create a epoll file descriptor each thread, every thread will just do its own job. You will lose the automatic thread communication that epoll provided. Concurrency will also be affected. (Because now every thread can only do its own work, and work can't be dispatched among threads according to how busy threads are).

By creating a epollfd and passing it to each thread as argument, threads can share it. So `thread`'s arg is defined as:

```c
// src/main.h
struct thread_args {
    int listenfd;
    int epollfd;
};
```

Then you can call `epoll_wait` at this epollfd in each thread. As `epoll_wait` is thread-safe, only one thread will be notified. **But**, you have to use `EPOLLET` to prevent what's called spurious wake-up due to the feature of level triggered mode. Again, the post mentioned above will give you a sight into this.

Done? **NOT ENOUGH**.

Remember to use `EPOLLONESHOT` mode. 

> EPOLLONESHOT:
>
> Sets the one-shot behavior for the associated file descriptor. This means that after an event is pulled out with epoll_wait(2) the associated file descriptor is internally disabled and no other events will be reported by the epoll interface. The user must call epoll_ctl() with EPOLL_CTL_MOD to rearm the file descriptor with a new event mask.

If you don't use oneshot (like me), two contiguous events on the same fd may cause this fd to be processed in two different threads at the same time. This behaviour may not be what you want. In my case, I debugged this out for a whole morning.

Remember to call `epoll_ctl` with `EPOLL_CTL_MOD` again after processing an event on the fd, as long as work isn't done.

### Non-blocking I/O

I think linux non-blocking I/O is not well documented. However you have to use it as edge triggered mode requires you to do so. You should be careful while performing non-blocking I/O.

First, how to set a file descriptor to non-blocking:

```c
void setnonblocking(int fd) {
    int old_option = fcntl(fd, F_GETFL);
    int new_option = old_option | O_NONBLOCK;
      
    fcntl(fd, F_SETFL, new_option);
}
```

When reading on non-blocking I/O, you have to pay attention to when the reading or writing is completed. In web server, you can decide this in server end. For example, it indicated that the request header was ended sending normally when you got a blank new line.

It of course feels good to `read` from the fd, and get all of what you expect until a blank new line. But in most case, in non-blocking mode, you will get an `-1` from `read` and `errno` though everything goes right. The `errno` will be set to `EAGAIN` or `EWOULDBLOCK`, which indicates *source temporarily unavailable*.

So you should write code like this:

```c
if (ret < 0) {
    if (errno == EAGAIN || errno == EWOULDBLOCK) {
        // read end normally
        break;
    } else {
        perror("read");
        break;
    }
} else if (ret == 0) {
    // EOF encountered
    break;
else {
    // --snippet--
}
```

The client may also, e.g., send half of the header, then send the remaining half after processing some work. You can't just wait the data to come. The server has other clients to serve. In both case, you have to deal with it. You have to detect whether the `read`ing is end, and if not, to save the status and continue on it when another event arrives on the fd.

So how to save status?

### Save status in `epoll_event.data.ptr`

Ok, a natural choice came to some people (ok, that's also me, and some of my classmates) that we should establish a data structure like map to map connection file descriptor to status and fetch from it when an epoll event come and this map has to be thread-safe and it is hard in pure C because C hasn't provided itself so let us implement it first!

When I was thinking on whether to implement a hashmap myself or using C++, I found that ... `epoll_event.data` is in fact a union and you could use `ptr` field instead of `fd` field to store other status. All you have to do is to define your status class, malloc it,  assign it to the `ptr` and free it after all the work is done. I have described my `HttpStatus` class above.

## Other things you should notice

- Use `sendfile` to prevent kernel space to user space copy while sending data to client. It will significantly improve your throughput.
- I only implement `GET` method on the server.
- Remember to write exception handling. It can also help you while debugging.

## Load test

Load test on my dual core Ubuntu Virtual Machine:

![server_load_test](/assets/img/posts/server_load_test.png)
