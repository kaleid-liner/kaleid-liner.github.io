module Jekyll 
    module ReadTime
        def read_time(content)
            wpm = 180
            count = content.split.size
            minutes = (count / wpm).floor
            str_minute = minutes === 1 ? 'minute' : 'minutes'
            minutes > 0 ? "#{minutes} #{str_minute}" : "less than one minute"
        end
    end
end

Liquid::Template.register_filter(Jekyll::ReadTime)