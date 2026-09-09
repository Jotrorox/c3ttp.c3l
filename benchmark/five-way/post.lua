wrk.method = "POST"
wrk.body = string.rep("x", 256)
wrk.headers["Content-Type"] = "application/octet-stream"
