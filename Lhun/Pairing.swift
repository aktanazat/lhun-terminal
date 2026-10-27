import Foundation

/// A Mac or server that a `lhun://pair` link put in a host's place: where it is, who to sign in as, and the
/// host keys to hold it to.
struct PairedHost: Codable, Equatable, Sendable {
    /// The place it takes: "mac" or "server".
    let id: String
    let machine: String
    let address: String
    let user: String
    let hostKeys: [String]
    let port: Int?
    let codeURL: URL?
}

/// Pairing a new machine: a script he pastes into the machine's terminal, or hands to an agent there, adds
/// this device's key and answers with a `lhun://pair` link; the link, pasted into Lhûn or scanned as a QR code,
/// puts the machine in its host's place.
enum Pairing {
    /// The key types Lhûn can hold a host to.
    private static let keyTypes: Set<String> = [
        "ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521",
    ]
    private static let addressCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.:-")
    private static let userCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")

    /// The machine a pairing link names, or nil for any other link or one with a part missing or malformed.
    static func host(in url: URL) -> PairedHost? {
        guard LhunLink.isLhun(url), url.host() == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let keys = items.filter { $0.name == "key" }.compactMap { $0.value.flatMap(hostKey) }
        guard let role = value("role"), Host.builtIn.contains(where: { $0.id == role }),
              let address = value("address"), !address.isEmpty, address.count <= 253,
              address.unicodeScalars.allSatisfy(addressCharacters.contains),
              let user = value("user"), !user.isEmpty, user.count <= 64,
              user.unicodeScalars.allSatisfy(userCharacters.contains),
              !keys.isEmpty, keys.count == items.count(where: { $0.name == "key" })
        else { return nil }
        let port: Int?
        if let text = value("port") {
            guard let number = Int(text), (1...65535).contains(number) else { return nil }
            port = number
        } else {
            port = nil
        }
        let codeURL: URL?
        if let text = value("code") {
            guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
                  ["http", "https"].contains(scheme), url.host() != nil,
                  url.user() == nil, url.password() == nil else { return nil }
            codeURL = url
        } else {
            codeURL = nil
        }
        let machine = value("name").map { String($0.prefix(64)) }.flatMap { $0.isEmpty ? nil : $0 } ?? address
        return PairedHost(id: role, machine: machine, address: address, user: user, hostKeys: keys, port: port, codeURL: codeURL)
    }

    /// The pairing link pasted as text: the first word that is one.
    static func host(inText text: String) -> PairedHost? {
        text.split(whereSeparator: \.isWhitespace).lazy.compactMap { URL(string: String($0)) }.compactMap(host(in:)).first
    }

    /// A host key as its type and base64 body, without the comment a `.pub` file ends with.
    private static func hostKey(_ text: String) -> String? {
        let parts = text.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2, keyTypes.contains(String(parts[0])), Data(base64Encoded: String(parts[1])) != nil
        else { return nil }
        return "\(parts[0]) \(parts[1])"
    }

    /// Pasted into a terminal on the machine, by hand or by an agent: adds this device's key, checks that SSH,
    /// tmux and Tailscale are there, prints the pairing link, puts it on the clipboard, which Universal
    /// Clipboard carries to this device, and draws it as a QR code where `qrencode` is installed. It runs in
    /// zsh, bash or sh, and running it twice adds the key once.
    static func script(deviceKey: String) -> String {
        // An interactive zsh takes no comments and expands "!" in double quotes, so the script holds neither.
        #"""
        lhun_pair() {
        k='\#(deviceKey)'
        mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh" && touch "$HOME/.ssh/authorized_keys" && chmod 600 "$HOME/.ssh/authorized_keys" || return 1
        grep -qxF "$k" "$HOME/.ssh/authorized_keys" || printf '%s\n' "$k" >> "$HOME/.ssh/authorized_keys"
        t=$(command -v tailscale || echo /Applications/Tailscale.app/Contents/MacOS/Tailscale)
        a=$("$t" ip -4 2>/dev/null | head -n 1)
        [ -n "$a" ] || { echo "Turn Tailscale on here, then paste this again."; return 1; }
        if [ "$(uname)" = Darwin ]; then
        r=mac; n=$(scutil --get ComputerName)
        nc -z 127.0.0.1 22 2>/dev/null || { echo "Turn on Remote Login in System Settings, General, Sharing, then paste this again."; open "x-apple.systempreferences:com.apple.Sharing-Settings.extension"; return 1; }
        else
        r=server; n=$(hostname)
        fi
        command -v tmux >/dev/null || [ -x /opt/homebrew/bin/tmux ] || [ -x /usr/local/bin/tmux ] || echo "Lhûn needs tmux here: brew install tmux, or apt install tmux."
        l="lhun://pair?role=$r&name=$(lhun_enc "$n")&address=$a&user=$(lhun_enc "$(id -un)")"
        for f in /etc/ssh/ssh_host_ed25519_key.pub /etc/ssh/ssh_host_ecdsa_key.pub; do
        [ -r "$f" ] && l="$l&key=$(lhun_enc "$(cut -d ' ' -f 1,2 "$f")")"
        done
        printf '\n%s\n\n' "$l"
        command -v qrencode >/dev/null && qrencode -t ansiutf8 "$l"
        command -v pbcopy >/dev/null && printf '%s' "$l" | pbcopy && echo "The link is on the clipboard. Paste it in Lhûn."
        return 0
        }
        lhun_enc() { printf '%s' "$1" | od -An -tx1 -v | tr -d ' \n' | sed 's/../%&/g'; }
        lhun_pair; unset -f lhun_pair lhun_enc
        """#
    }

    /// The same steps in words, for an agent on the machine when the script will not do.
    static func agentInstructions(deviceKey: String) -> String {
        """
        Pair this machine with Lhûn, my iPad terminal app. Do each step, and tell me plainly if one fails.

        1. Add this exact line to ~/.ssh/authorized_keys once (make ~/.ssh mode 700 and the file mode 600 if you create them):
        \(deviceKey)
        2. Make sure SSH is on. On a Mac that is Remote Login in System Settings > General > Sharing; `nc -z 127.0.0.1 22` succeeds once it is. If it is off, open that pane for me and wait.
        3. Make sure tmux is installed (on a Mac: brew install tmux).
        4. Find this machine's Tailscale IPv4 address with `tailscale ip -4` (on a Mac the command may be /Applications/Tailscale.app/Contents/MacOS/Tailscale).
        5. Build this link, percent-encoding every value:
        lhun://pair?role=ROLE&name=NAME&address=ADDRESS&user=USER&key=KEY&key=KEY
        ROLE is mac on macOS and server on Linux. NAME is the computer's name (scutil --get ComputerName on a Mac, hostname on Linux). ADDRESS is the Tailscale IPv4 address. USER is `id -un`. Each KEY is the first two fields (type and base64) of /etc/ssh/ssh_host_ed25519_key.pub and of /etc/ssh/ssh_host_ecdsa_key.pub, one key parameter per file that exists.
        6. Print the link and copy it to the clipboard (pbcopy on a Mac). If qrencode is installed, also show it with qrencode -t ansiutf8 so I can scan it.
        7. In the Lhûn source checkout on this host, optionally run tools/status/install.sh and tools/agents/install.sh, so Lhûn sees what each program is doing and agents can open sessions beside their own.
        """
    }
}
