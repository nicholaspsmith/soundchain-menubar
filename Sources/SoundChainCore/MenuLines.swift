// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

/// The text of the menu's read-only block and of the rows that change while it
/// is open. The menu stays open after an option is picked, so these are
/// refreshed in place rather than on the next opening.
public enum MenuLines {
    /// Menu lines longer than this are cut short (full text in the tooltip), so a
    /// long device name or error cannot stretch the whole menu.
    public static let limit = 34

    /// `text` cut to `limit` characters with an ellipsis, and the full text as a
    /// tooltip when it was cut.
    public static func fit(_ text: String, limit: Int = MenuLines.limit) -> (title: String, toolTip: String?) {
        guard text.count > limit else { return (text, nil) }
        return (String(text.prefix(limit - 1)) + "…", text)
    }

    /// The read-only block at the top of the menu, in order: the engine's status,
    /// a one-off notice, the headphones line, each effect's error, the UAD warning.
    public static func info(status: [String], notice: String?, headphones: String?,
                            errors: [String], uadWarning: String?) -> [String] {
        status + [notice, headphones].compactMap { $0 } + errors + [uadWarning].compactMap { $0 }
    }

    /// "Reconnect <name>", or "Reconnecting <name>…" while it runs.
    public static func reconnect(_ name: String, inProgress: Bool) -> String {
        inProgress ? "Reconnecting \(name)…" : "Reconnect \(name)"
    }

    public static let copyRestart = "Copy Restart Command"
    /// What Copy Restart Command says once clicked, since the menu stays open.
    public static let copiedRestart = "Restart Command Copied"
}
