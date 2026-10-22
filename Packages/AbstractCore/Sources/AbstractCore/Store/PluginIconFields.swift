import Foundation
import GRDB

public enum PluginIconFields {
    public static let limit = 32

    public static func validKey(_ key: String) -> Bool {
        !key.isEmpty && key.utf8.count <= 64 && key.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 46 || $0 == 45
        }
    }
}

public extension Store {
    func pluginIcon(pluginId: String, key: String) -> IconValue? {
        guard PluginIconFields.validKey(key) else { return nil }
        return try? writer.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT icon_symbol, icon_color, icon_image_path FROM plugin_icon_fields WHERE plugin_id = ? AND field_key = ?",
                                             arguments: [pluginId, key]) else { return nil }
            return IconValue(symbol: try row.decode(forColumn: "icon_symbol"),
                             color: try row.decode(forColumn: "icon_color"),
                             imagePath: try row.decode(forColumn: "icon_image_path"))
        }
    }

    func savePluginIcon(_ value: IconValue, pluginId: String, key: String) throws {
        guard PluginIconFields.validKey(key) else { throw AbstractError.message("That icon field key isn't valid.") }
        try writer.write { db in
            if value.isDefault {
                try db.execute(sql: "DELETE FROM plugin_icon_fields WHERE plugin_id = ? AND field_key = ?", arguments: [pluginId, key])
            } else {
                let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM plugin_icon_fields WHERE plugin_id = ?", arguments: [pluginId]) ?? 0
                let exists = try Bool.fetchOne(db, sql: "SELECT 1 FROM plugin_icon_fields WHERE plugin_id = ? AND field_key = ?", arguments: [pluginId, key]) ?? false
                guard exists || count < PluginIconFields.limit else { throw AbstractError.message("This plugin has too many icon fields.") }
                try db.execute(sql: """
                    INSERT INTO plugin_icon_fields (plugin_id, field_key, icon_symbol, icon_color, icon_image_path)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(plugin_id, field_key) DO UPDATE SET
                      icon_symbol = excluded.icon_symbol, icon_color = excluded.icon_color,
                      icon_image_path = excluded.icon_image_path
                    """, arguments: [pluginId, key, value.symbol, value.color, value.imagePath])
            }
        }
    }

    func deletePluginIcons(pluginId: String) throws -> [String] {
        try writer.write { db in
            let paths = try String.fetchAll(db, sql: "SELECT icon_image_path FROM plugin_icon_fields WHERE plugin_id = ? AND icon_image_path IS NOT NULL",
                                            arguments: [pluginId])
            try db.execute(sql: "DELETE FROM plugin_icon_fields WHERE plugin_id = ?", arguments: [pluginId])
            return paths
        }
    }

    func managedIconPaths() -> Set<String> {
        (try? writer.read { db in
            var paths = Set<String>()
            for table in ["projects", "profiles", "workflows", "plugin_icon_fields"] {
                paths.formUnion(try String.fetchAll(db, sql: "SELECT icon_image_path FROM \(table) WHERE icon_image_path IS NOT NULL"))
            }
            return paths
        }) ?? []
    }
}
