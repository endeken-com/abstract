import Foundation
import AbstractCore

extension AppModel {
    func setProfileIcon(_ id: String, value: IconValue) {
        guard var item = profile(id) else { return }
        let old = item.iconImagePath
        item.iconValue = value
        do {
            try store.save(item)
            if let index = profiles.firstIndex(where: { $0.id == id }) { profiles[index] = item }
            if old != value.imagePath { ProjectIconStore.discard(old) }
        } catch { flash(error.localizedDescription, isError: true) }
    }

    func setWorkflowIcon(_ id: String, value: IconValue) {
        guard var item = workflow(id) else { return }
        let old = item.iconImagePath
        item.iconValue = value
        do {
            try store.save(item)
            if let index = workflows.firstIndex(where: { $0.id == id }) { workflows[index] = item }
            if old != value.imagePath { ProjectIconStore.discard(old) }
        } catch { flash(error.localizedDescription, isError: true) }
    }

    func importProfileIcon(_ id: String, from source: URL) {
        do {
            let path = try ProjectIconStore.save(source, owner: .profile)
            guard var item = profile(id) else { ProjectIconStore.discard(path); return }
            let old = item.iconImagePath
            item.iconImagePath = path
            do {
                try store.save(item)
                if let index = profiles.firstIndex(where: { $0.id == id }) { profiles[index] = item }
                ProjectIconStore.discard(old)
            } catch {
                ProjectIconStore.discard(path)
                throw error
            }
        } catch { flash(error.localizedDescription, isError: true) }
    }

    func importWorkflowIcon(_ id: String, from source: URL) {
        do {
            let path = try ProjectIconStore.save(source, owner: .workflow)
            guard var item = workflow(id) else { ProjectIconStore.discard(path); return }
            let old = item.iconImagePath
            item.iconImagePath = path
            do {
                try store.save(item)
                if let index = workflows.firstIndex(where: { $0.id == id }) { workflows[index] = item }
                ProjectIconStore.discard(old)
            } catch {
                ProjectIconStore.discard(path)
                throw error
            }
        } catch { flash(error.localizedDescription, isError: true) }
    }
}
