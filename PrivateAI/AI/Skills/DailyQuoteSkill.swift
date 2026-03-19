import Foundation

/// Provides motivational quotes, proverbs, and wisdom.
/// All quotes are stored locally — no network required.
/// Users can ask for a random quote, a category-specific one, or the "quote of the day".
struct DailyQuoteSkill: ClawSkill {

    let id = "dailyQuote"

    func canHandle(intent: QueryIntent) -> Bool {
        if case .dailyQuote = intent { return true }
        return false
    }

    func execute(intent: QueryIntent, context: SkillContext, completion: @escaping (String) -> Void) {
        guard case .dailyQuote(let category) = intent else {
            completion(randomQuote(from: allQuotes))
            return
        }

        switch category {
        case .motivational:
            completion(randomQuote(from: motivationalQuotes))
        case .wisdom:
            completion(randomQuote(from: wisdomQuotes))
        case .life:
            completion(randomQuote(from: lifeQuotes))
        case .perseverance:
            completion(randomQuote(from: perseveranceQuotes))
        case .dailyPick:
            completion(dailyPick(context: context))
        case .random:
            completion(randomQuote(from: allQuotes))
        }
    }

    // MARK: - Response Builders

    private func randomQuote(from pool: [(String, String)]) -> String {
        let (quote, author) = pool[Int.random(in: 0..<pool.count)]
        return formatQuote(quote, author: author)
    }

    /// Deterministic "quote of the day" based on the current date.
    private func dailyPick(context: SkillContext) -> String {
        let cal = Calendar.current
        let day = cal.ordinality(of: .day, in: .year, for: Date()) ?? 1
        let index = day % allQuotes.count
        let (quote, author) = allQuotes[index]

        let userName = context.profile.name.isEmpty ? "" : "，\(context.profile.name)"
        let header = "📅 今日语录\(userName)：\n\n"
        return header + formatQuote(quote, author: author)
    }

    private func formatQuote(_ quote: String, author: String) -> String {
        let emojis = ["💡", "✨", "🌟", "📖", "🔥", "🌈", "💎", "🎯"]
        let emoji = emojis[Int.random(in: 0..<emojis.count)]
        return "\(emoji) 「\(quote)」\n\n—— \(author)"
    }

    // MARK: - Quote Database

    private var allQuotes: [(String, String)] {
        motivationalQuotes + wisdomQuotes + lifeQuotes + perseveranceQuotes
    }

    private var motivationalQuotes: [(String, String)] {
        [
            ("世上无难事，只怕有心人。", "中国谚语"),
            ("千里之行，始于足下。", "老子"),
            ("不积跬步，无以至千里；不积小流，无以成江海。", "荀子"),
            ("天行健，君子以自强不息。", "《周易》"),
            ("宝剑锋从磨砺出，梅花香自苦寒来。", "《警世贤文》"),
            ("有志者事竟成。", "《后汉书》"),
            ("业精于勤，荒于嬉；行成于思，毁于随。", "韩愈"),
            ("The only way to do great work is to love what you do.", "Steve Jobs"),
            ("Believe you can and you're halfway there.", "Theodore Roosevelt"),
            ("The future belongs to those who believe in the beauty of their dreams.", "Eleanor Roosevelt"),
            ("It does not matter how slowly you go as long as you do not stop.", "Confucius"),
            ("Success is not final, failure is not fatal: it is the courage to continue that counts.", "Winston Churchill"),
        ]
    }

    private var wisdomQuotes: [(String, String)] {
        [
            ("知之为知之，不知为不知，是知也。", "孔子"),
            ("三人行，必有我师焉。", "孔子"),
            ("学而不思则罔，思而不学则殆。", "孔子"),
            ("己所不欲，勿施于人。", "孔子"),
            ("上善若水。水善利万物而不争。", "老子"),
            ("知人者智，自知者明。", "老子"),
            ("读万卷书，行万里路。", "董其昌"),
            ("温故而知新，可以为师矣。", "孔子"),
            ("The only true wisdom is in knowing you know nothing.", "Socrates"),
            ("In the middle of difficulty lies opportunity.", "Albert Einstein"),
            ("Life is what happens when you're busy making other plans.", "John Lennon"),
            ("The unexamined life is not worth living.", "Socrates"),
        ]
    }

    private var lifeQuotes: [(String, String)] {
        [
            ("生活不止眼前的苟且，还有诗和远方。", "高晓松"),
            ("人生得意须尽欢，莫使金樽空对月。", "李白"),
            ("采菊东篱下，悠然见南山。", "陶渊明"),
            ("海内存知己，天涯若比邻。", "王勃"),
            ("山重水复疑无路，柳暗花明又一村。", "陆游"),
            ("人生如逆旅，我亦是行人。", "苏轼"),
            ("长风破浪会有时，直挂云帆济沧海。", "李白"),
            ("Happiness is not something ready made. It comes from your own actions.", "Dalai Lama"),
            ("Be yourself; everyone else is already taken.", "Oscar Wilde"),
            ("The purpose of our lives is to be happy.", "Dalai Lama"),
            ("Life is really simple, but we insist on making it complicated.", "Confucius"),
            ("You only live once, but if you do it right, once is enough.", "Mae West"),
        ]
    }

    private var perseveranceQuotes: [(String, String)] {
        [
            ("锲而不舍，金石可镂。", "荀子"),
            ("绳锯木断，水滴石穿。", "罗大经"),
            ("路漫漫其修远兮，吾将上下而求索。", "屈原"),
            ("故天将降大任于是人也，必先苦其心志，劳其筋骨。", "孟子"),
            ("古之立大事者，不惟有超世之才，亦必有坚忍不拔之志。", "苏轼"),
            ("失败是成功之母。", "中国谚语"),
            ("只要功夫深，铁杵磨成针。", "中国谚语"),
            ("Fall seven times, stand up eight.", "日本谚语"),
            ("It always seems impossible until it's done.", "Nelson Mandela"),
            ("Our greatest glory is not in never falling, but in rising every time we fall.", "Confucius"),
            ("Perseverance is not a long race; it is many short races one after the other.", "Walter Elliot"),
            ("Hard times don't create heroes. It is during the hard times when the hero within us is revealed.", "Bob Riley"),
        ]
    }
}
