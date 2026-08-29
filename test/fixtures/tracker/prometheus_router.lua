local router = require("klib.router").new("/prometheus")

router:add_filter(function(output)
    return "filtered:" .. output
end)

router:get("/metrics", function()
    return "tracker_metric 1\n"
end)

router:get("/view", function()
    return { name = "child" }
end, "<b>{{name}}</b>")

return router
