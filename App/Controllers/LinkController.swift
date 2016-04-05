import Vapor
import Redbird
import Foundation
import POSIXRegex

enum Vote: String {
    case Up = "up"
    case Down = "down"
}

class LinkController {
    required init(application: Application) {
        Log.info("Link controller created")
    }
    
    func index(request: Request) throws -> ResponseRepresentable {
        let news = try getTopNews()
        return try app.view("articles.mustache", context: ["articles": news, "params": request.parameters])
    }

    func show(request: Request, newsId: Int) throws -> ResponseRepresentable {
        let articles = try getNewsByIds(["\(newsId)"])
        let article = articles[0]
        return try app.view("article.mustache", context: ["article": article, "params": request.parameters])
    }
    
    func store(request: Request) throws -> ResponseRepresentable {
        return Json([
            "controller": "UserController.store"
        ])
    }

    /// Create a new instance.
    func add(request: Request) throws -> ResponseRepresentable  {
        if request.method == .Post {
            guard let title = request.data["title"]?.string else {
                return Json(["status": "err", "message": "Please include a title"])
            }

            guard let userId = request.parameters["userId"] else {
                return Json(["status": "err", "message": "Please log in before submitting"])
            }

            let time = "\(Int(NSDate().timeIntervalSince1970))"
            //let content = request.data["content"]?.string ?? ""
            
            var url = "-" //empty url
            // Check if link is provided
            if let link = request.data["url"]?.string where link != "url" {
                url = link
            } else if let text = request.data["text"]?.string where text != "text"  { //otherwise is a discussion
                url = "text://\(text)"
            }

            guard url.hasPrefix("https://") || url.hasPrefix("http://") || url.hasPrefix("text://") else {
                return Json(["status": "err", "message": "Dude, text is empty or that's an invalid link, only HTTP or HTTPS are allowed as schema."])
            }

            do {
                let newsId = try redis.incr("news.count") ?? -1
                try redis.hmset("news:\(newsId)", [
                    "id": "\(newsId)",
                    "title": title,
                    "url": url,
                    "userId": userId,
                    "ctime": time,
                    "score": "0",
                    "up": "0",
                    "down": "0",
                    "comments": "0"
                ])
                let (rank, error) = try voteNews("\(newsId)", userId: userId, vote: .Up)
                guard error == nil else {
                    return Json(["status": "err", "message": error!])
                }
                // Add the news to the user submitted news
                try redis.zadd("user.posted:\(userId)", time, "\(newsId)")
                // Add the news into the chronological view
                try redis.zadd("news.cron", time, "\(newsId)")
                // Add the news into the top view
                try redis.zadd("news.top", "\(rank)", "\(newsId)")

                return Json(["status": "ok", "id": "\(newsId)"])
            } catch (let e as RespError) {
                return Json(["status": "err", "message": e.message ?? "Something went wrong with Redis..."])
            } catch {
                return Json(["status": "err", "message": "Something went wrong..."])
            }
        } 

        return try app.view("submit.mustache", context: ["params": request.parameters])
    }

    // MARK: - Private functions
    private func voteNews(newsId: String, userId: String, vote: Vote) throws -> (Float, String?) {
        let up = redis.zscore("news.up:\(newsId)", userId)
        let down = redis.zscore("news.down:\(newsId)", userId)
        guard up == nil && down == nil else {
            return (-1, "Duplicated vote.")
        }

        guard let news = try getNewsByIds([newsId]).first else {
            return (-1, "News creating failed.")
        }

        // TODO: Check if user has enough Karma

        // News was not already voted by that user. Add the vote.
        // Note that even if there is a race condition here and the user may be
        // voting from another device/API in the time between the ZSCORE check
        // and the zadd, this will not result in inconsistencies as we will just
        // update the vote time with ZADD.
        let time = "\(Int(NSDate().timeIntervalSince1970))"
        if try redis.zadd("news.\(vote.rawValue):\(newsId)", time, userId) > 0 {
            try redis.hincrby("news:\(newsId)", vote.rawValue, "1")
        }
        if (vote == .Up) {
            try redis.zadd("user.saved:\(userId)", time, newsId)
        }

        if (news["userId"] != userId) {
            switch(vote) {
                case .Up:
                    try redis.zadd("user.saved:\(userId)", time, newsId)
                case .Down:
                    break
            }    
        }

        let score = try computeNewsScore(news)
        try redis.hmset("news:\(newsId)", ["score": "\(score)"])

        do {
           try redis.zadd("news.top", "\(score)", newsId)     
        } catch let e {
            print("\(e)")
        }
        
        if let newsUserId = news["userId"] where userId != newsUserId {
            switch(vote) {
                case .Up:
                    try incrementUserKarma(newsUserId)
                case .Down:
                    try incrementUserKarma(newsUserId, by: -1)
            }
        }

        return (score, nil)
    }

    private func computeNewsScore(news: [String: String], gravity: Double = 1.8) throws -> Float {        
        guard let newsId = news["id"], newsTime = news["ctime"] else {
            return -1.0
        }

        let upvotes = try redis.zrange("news.up:\(newsId)", "0", "-1", withScores: true)
        let downvotes = try redis.zrange("news.down:\(newsId)", "0", "-1", withScores: true)
        // FIXME: For now we are doing a naive sum of votes, without time-based
        // filtering, nor IP filtering.
        // We could use just ZCARD here of course, but I'm using ZRANGE already
        // since this is what is needed in the long term for vote analysis.
        let votes = Double(upvotes.count - downvotes.count)
        
        let newsDate = NSDate(timeIntervalSince1970: (Double(newsTime) ?? 0) ?? 0.0)
        let timeDeltaInHours = fabs(newsDate.timeIntervalSinceNow / 3600.0) 
        return Float((votes - 1.0) / pow((timeDeltaInHours + 2.0), gravity))
    }

    private func incrementUserKarma(userId: String, by: Int = 1) throws {
        let userkey = "user:\(userId)"
        try redis.hincrby(userkey, "karma", "\(by)")
    }

    private func getTopNews(start: Int = 0, count: Int = 30) throws -> [[String:String]] {
        //let nItems = try redis.zcard("news.top")
        let newsIds = try redis.zrevrange("news.top", "\(start)", "\(start + (count - 1))")
        let result = try getNewsByIds(newsIds)
        return result
    }

    private func getNewsByIds(ids: [String]) throws -> [[String:String]] {
        let news = try ids.map({ try redis.hgetall("news:\($0)") })
        var result = [[String:String]]()
        for var item in news {
            if let userId = item["userId"] {
                let user = try redis.hgetall("user:\(userId)")
                item["username"] = user["username"]!
            }
            if let url = item["url"] {
                if let hostname = hostnameFromURL(url) {
                    item["hostname"] = hostname
                } else if url.hasPrefix("text://"), let newsId = item["id"] {
                    item["url"] = "/news/\(newsId)"
                    let textSchema = try! Regex(pattern: "text://")
                    let encodedText = textSchema.replace(url, withTemplate: "")
                    print("encoded -> \(encodedText)")
                    if let decodedData = NSData(base64EncodedString: encodedText, options: NSDataBase64DecodingOptions(rawValue: 0)),
                        let decodedString = String(data: decodedData, encoding: NSUTF8StringEncoding) {
                            item["text"] = decodedString 
                    }
                }
            }
            if let time = item["ctime"] {
                item["posted"] = humanReadablePostTime(Int(time) ?? 0)
            }
            result.append(item)
        }
        return result
    }
}

private func hostnameFromURL(url: String) -> String? {
    guard url.hasPrefix("https://") || url.hasPrefix("http://") else {
        return nil
    }
    
    let http = try! Regex(pattern: "http://")
    let https = try! Regex(pattern: "https://")
    let www = try! Regex(pattern: "www.")
    var striped = http.replace(url, withTemplate: "")
    striped = https.replace(striped, withTemplate: "")
    striped = www.replace(striped, withTemplate: "")

    return striped.characters.split(separator: "/", maxSplits:1024, omittingEmptySubsequences: true).map { String($0) }[0]
}

private func humanReadablePostTime(time: Int) -> String {
    let newsDate = NSDate(timeIntervalSince1970: (Double(time) ?? 0) ?? 0.0)
    let delta = abs(Int(newsDate.timeIntervalSinceNow))

    if delta < 3 {
        return "just now"
    } else if delta < 60 {
        return "\(delta) seconds ago"
    } else if delta < 120 {
        return "1 minute ago"
    } else if delta < 3600 {
        return "\(delta / 60) minutes ago"
    } else if delta < 7200 {
        return "1 hour ago"
    } else if delta < 86400 {
        return "\(delta / 3600) hours ago"
    } else if delta < 172800 {
        return "1 day ago"
    }

    return "\((delta / 86400) + 1) days ago"
}