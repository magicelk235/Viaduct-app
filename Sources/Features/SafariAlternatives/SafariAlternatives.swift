import Foundation

/// An official Safari build of a Chrome extension, published by the same vendor.
struct SafariAlternative {
    /// Product name as the user knows it, e.g. "1Password".
    let name: String
    /// Mac App Store page, or the vendor's own Safari download page when the
    /// extension isn't distributed through the App Store.
    let url: URL
}

enum SafariAlternatives {
    static func lookup(chromeId: String) -> SafariAlternative? {
        table[chromeId]
    }

    /// Chrome Web Store id -> official Safari version of the same product.
    ///
    /// Maintained by hand. Every row was checked against the live Chrome Web
    /// Store listing and the Mac App Store record (same developer, Mac build
    /// that is or contains the Safari extension) before it went in. Pointing a
    /// user at the wrong app, or at a look-alike from another developer, is
    /// worse than saying nothing, so don't add rows from memory: verify both
    /// ids first, and drop rows whose Safari version disappears.
    private static let table: [String: SafariAlternative] = [
        "aeblfdkhhhdcdjpifhhbdiojplfjncoa": .appStore("1Password", id: 1569813296),            // 1Password
        "gighmmpiobklfepjocnamgkkbiglidom": .appStore("AdBlock", id: 1402042596),              // AdBlock
        "cfhdojbkjhnklbpkdaibdccddilifddb": .appStore("Adblock Plus", id: 1432731683),         // Adblock Plus
        "bgnkhhnnamicmpeenaelnjfhikgbkllg": .appStore("AdGuard", id: 1440147259),              // AdGuard
        "nngceckbapebfimnlniiiahkandclblb": .appStore("Bitwarden", id: 1352778147),            // Bitwarden (the Safari extension ships inside the desktop app)
        "nenlahapcbofgnanklpelkaejcehkggg": .appStore("Capital One Shopping", id: 1477110326), // Capital One Shopping
        "mdjildafknihdffpkfmmpnpoiajfjnjd": .appStore("Consent-O-Matic", id: 1606897889),      // Consent-O-Matic
        "eimadpbcbfnmbkopoojfekhnkhdbieeh": .appStore("Dark Reader", id: 1438243180),          // Dark Reader
        "fdjamakpfbbddfjaooikfcpapjohcfmg": .appStore("Dashlane", id: 517914548),              // Dashlane (Safari extension comes with the Mac app)
        "enamippconapkdmgfgjchkhakpfinmaj": .appStore("DeArrow", id: 6451469297),              // DeArrow
        "kmcfomidfpdkfieipokbalgegidffkal": .appStore("Enpass", id: 732710998),                // Enpass
        "pioclpoplcdbaefihamjohnefbikjilc": .appStore("Evernote Web Clipper", id: 1481669779), // Evernote Web Clipper
        "mlomiejdfkolichcflejclcbmpeaniij": .appStore("Ghostery", id: 6504861501),             // Ghostery
        "blillmbchncajnhkjfdnincfndboieik": .appStore("Glasp", id: 1605690124),                // Glasp Web Highlighter
        "kbfnbcaeplbcioakkpcpgfkobkghlhen": .appStore("Grammarly", id: 1462114288),            // Grammarly
        "bpoadfkcbjbfhfodiogcnhhhpibjhbnh": .appStore("Immersive Translate", id: 6447957425),  // Immersive Translate
        "cdglnehniifkbagbbombnjghhcihifij": .appStore("Kagi", id: 1622835804),                 // Kagi Search
        "bfogiafebfohielmmehodmfbbebbbpei": .appStore("Keeper", id: 6444685332),               // Keeper
        "hdokiejnpimakedhajhdlcegeplioahd": .appStore("LastPass", id: 6504626762),             // LastPass
        "ihmgiclibbndffejedjimfjmfoabpcke": .appStore("Mate Translate", id: 1005088137),       // Mate Translate
        "dagcmkpagjlhakfdhnbomgmjdpkdklff": .appStore("Mendeley Web Importer", id: 1577516695), // Mendeley Web Importer
        "laookkfknpbbblfpciffpaejjkokdgca": .appStore("Momentum", id: 1564329434),             // Momentum
        "eiaeiblijfjekdanodkjadfinkhbfgcd": .appStore("NordPass", id: 6443917910),             // NordPass
        "fooolghllnmhmmndgjiamiiodkpenpbb": .appStore("NordPass", id: 6443917910),             // NordPass (legacy Chrome extension, retiring but still installed)
        "knheggckgoiihginacbkhaalnibhilkk": .web("Notion Web Clipper", "https://www.notion.com/web-clipper"), // Notion Web Clipper (DMG from Notion, no longer on the App Store)
        "cnjifjpddelmedmihgijeibhnjfabmlf": .appStore("Obsidian Web Clipper", id: 6720708363), // Obsidian Web Clipper
        "glnpjglilkicbckjpbgcfkogebgllemb": .appStore("Okta Browser Plugin", id: 1439967473),  // Okta Browser Plugin
        "chphlpgkkbolifaimnlloiipkdnihall": .appStore("OneTab", id: 1540160809),               // OneTab
        "bmnlcjabgnpnenekpadlanbbkooimhnj": .appStore("PayPal Honey", id: 1472777122),         // PayPal Honey
        "ghmbeldphafepmbegfdlkpapadhbakde": .appStore("Proton Pass", id: 6502835663),          // Proton Pass
        "iidnbdjijdkbmajdffnidomddglmieko": .appStore("QuillBot", id: 6738683741),             // QuillBot
        "ldgfbffkinooeloadekpmfoklnobpien": .appStore("Raindrop.io", id: 1549370672),          // Raindrop.io
        "chhjbpecpncaggjpdakmflnfcopglcmi": .appStore("Rakuten Cash Back", id: 1451893560),    // Rakuten Cash Back
        "jjhefcfhmnkfeepcpnilbbkaadhngkbi": .appStore("Readwise Reader", id: 1640236961),      // Readwise Reader
        "jjfblogammkiefalfpafidabbnamoknm": .appStore("RetailMeNot", id: 1588381926),          // RetailMeNot
        "pnlccmojcmeohlpggmfnbbiapkmbliob": .appStore("RoboForm", id: 1464513335),             // RoboForm
        "dphilobhebphkdjbpfohgikllaljmgbn": .appStore("SimpleLogin", id: 6475835429),          // SimpleLogin
        "mnjggcdmjocbbbhaepdhchncahnbgone": .appStore("SponsorBlock", id: 1573461917),         // SponsorBlock
        "dhdgffkkebhmkfjojejmpbldmpobfkfo": .appStore("Tampermonkey", id: 6738342400),         // Tampermonkey
        "jldhpllghnbhlbpcmnajkpdmadaolakh": .appStore("Todoist", id: 585829637),               // Todoist (Safari extension comes with the Mac app)
        "ddkjiahejlhfcafbddmgiahcphecmpfh": .appStore("uBlock Origin Lite", id: 6745342698),   // uBlock Origin Lite
        "gppongmhjkpfnbhagpmjfkannfbllamg": .appStore("Wappalyzer", id: 1520333300),           // Wappalyzer
        "ekhagklcjbdpajgpjgmbionohlpdbjgc": .web("Zotero Connector", "https://www.zotero.org/support/kb/zotero_connector_and_safari"), // Zotero Connector (bundled with the Zotero app)
    ]
}

private extension SafariAlternative {
    static func appStore(_ name: String, id: Int) -> SafariAlternative {
        SafariAlternative(name: name, url: URL(string: "https://apps.apple.com/app/id\(id)")!)
    }

    static func web(_ name: String, _ url: String) -> SafariAlternative {
        SafariAlternative(name: name, url: URL(string: url)!)
    }
}
