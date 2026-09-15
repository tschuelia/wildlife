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

    package static func isAutomaticallyAllocated(_ candidate: String) -> Bool {
        if candidate == SessionHistoryPolicy.historicalEmoji
            || candidate == "🐾"
            || orderedPool.contains(candidate) {
            return true
        }
        if candidate.hasPrefix("🐾"), Int(candidate.dropFirst()) != nil {
            return true
        }
        let parts = candidate.map(String.init)
        guard parts.count == 2, parts[0] != parts[1] else { return false }
        let seeds = Set(wildlife + nature)
        return parts.allSatisfy(seeds.contains)
    }

    public static func isSingleEmoji(_ candidate: String) -> Bool {
        guard candidate.count == 1, !candidate.isEmpty else { return false }
        let scalars = Array(candidate.unicodeScalars)
        if scalars.contains(where: { $0.properties.isEmojiPresentation }) { return true }

        let hasEmojiBase = scalars.contains {
            $0.properties.isEmoji && $0.value != 0xFE0F && $0.value != 0x20E3
        }
        let hasEmojiStyle = scalars.contains { $0.value == 0xFE0F }
        let hasKeycap = scalars.contains { $0.value == 0x20E3 }
        return hasEmojiBase && (hasEmojiStyle || hasKeycap)
    }
}
