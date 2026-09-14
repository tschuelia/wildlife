import Foundation

public enum EmojiAllocator {
    public static let wildlife = Array("🦓🦒🐘🐯🦁🦘🦨🦦🦏🦛🦥🐻‍❄️🐨🦬🦌🫎🦙🐆🐅🦝🦡🐊🦈🐋🐳🐬🦭🐢🦎🐍🦖🦕🦅🦉🦜🦚🦩🕊️🐦🐧🪿🦢🐺🐗🐴🐒🦍🦧🦊")
        .map(String.init)
    public static let animals = Array("🐶🐱🐭🐹🐰🐻🐼🐮🐷🐽🐸🐵🙈🙉🙊🐔🐤🐣🐥🦆🐦‍⬛🐦‍🔥🐝🪲🐞🦋🐌🐛🪱🐜🪰🪲🪳🦟🦗🕷️🦂🦀🦞🦐🦑🐙🪼🐠🐟🐡🐎🐂🐃🐄🐖🐏🐑🦛🫏🫏🐐🐕🐩🦮🐕‍🦺🐈🐈‍⬛🪽🪶")
        .map(String.init)
    public static let nature = Array("🌲🌳🌴🌵🌾🌿☘️🍀🍁🍂🍃🪴🎋🎍🍄🪺🪹🌱🌷🌹🥀🪻🪷🌺🌸🌼🌻🌞🌝🌛🌜🌚🌕🌖🌗🌘🌑🌒🌓🌔🌙🌎🌍🌏🪐💫⭐️🌟✨⚡️☄️🔥🌈☀️🌤️⛅️🌥️☁️🌦️🌧️⛈️🌩️🌨️❄️☃️⛄️🌬️💨💧💦☔️☂️🌊")
        .map(String.init)
    public static let symbols = Array("❤️🧡💛💚💙💜🖤🤍🤎🩷🩵🩶💔❣️💕💞💓💗💖💘💝💟☮️✝️☪️🕉️☸️✡️🔯🕎☯️☦️🛐⛎♈️♉️♊️♋️♌️♍️♎️♏️♐️♑️♒️♓️🆔⚛️🉑☢️☣️📴📳🈶🈚️🈸🈺🈷️✴️🆚💮🉐㊙️㊗️🈴🈵🈹🈲🅰️🅱️🆎🆑🅾️🆘❌⭕️🛑⛔️📛🚫💯💢♨️🚷🚯🚳🚱🔞📵❗️❕❓❔‼️⁉️🔅🔆〽️⚠️🚸🔱⚜️🔰♻️✅🈯️💹❇️✳️❎🌐💠Ⓜ️🌀💤🏧🚾♿️🅿️🛗")
        .map(String.init)

    public static var orderedPool: [String] {
        var seen = Set<String>()
        return (wildlife + animals + nature + symbols).filter { seen.insert($0).inserted }
    }

    public static func next(used: Set<String>) -> String {
        if let emoji = orderedPool.first(where: { !used.contains($0) }) { return emoji }
        let seeds = wildlife + nature
        for first in seeds {
            for second in seeds where first != second {
                let pair = first + second
                if !used.contains(pair) { return pair }
            }
        }
        return "🐾" + String(used.count + 1)
    }

    public static func isSingleEmoji(_ candidate: String) -> Bool {
        guard candidate.count == 1, !candidate.isEmpty else { return false }
        return candidate.unicodeScalars.contains {
            $0.properties.isEmojiPresentation || $0.properties.isEmoji
        }
    }
}
