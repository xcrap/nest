import Foundation
import NestLib

enum ProjectLifecycleTests {
    static func runAll() -> (passed: Int, failed: Int) {
        var passed = 0, failed = 0
        func check(_ condition: Bool, _ message: String) {
            if condition { passed += 1 }
            else { failed += 1; print("  FAIL: \(message)") }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nest-project-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let project = AppProject(id: "webcams", name: "Webcams", hostname: "webcams.test", directory: directory.path, port: 3999, command: "bun run start")
            var plan = ProjectLaunchPlanner.plan(for: project)
            let primary = "app.nest.app-nest.project.webcams"
            let legacy = "app.nest.dev-nest-app.project.webcams"
            plan.definition.label = primary
            let file = directory.appendingPathComponent(legacy + ".plist")
            func writeJob(label: String = "app.nest.dev-nest-app.project.webcams", path: String, port: String = "3999") throws {
                let plist: [String: Any] = ["Label": label, "WorkingDirectory": path, "EnvironmentVariables": ["PORT": port]]
                let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                try data.write(to: file)
            }
            func compatible(_ plan: ProjectLaunchPlan) -> [String] {
                LaunchAgentService.compatibleProjectLabels(for: plan, directory: directory.path)
            }
            check(compatible(plan).isEmpty, "missing legacy job is not adopted")
            try writeJob(path: directory.path)
            check(compatible(plan) == [legacy], "same project in development namespace is recognized")
            try writeJob(path: directory.path + "/other")
            check(compatible(plan).isEmpty, "same ID in another directory is not adopted")
            try writeJob(path: directory.path, port: "4000")
            check(compatible(plan).isEmpty, "same ID on another port is not adopted")
            try writeJob(label: "unrelated.service", path: directory.path)
            check(compatible(plan).isEmpty, "mismatched plist label is rejected")
            try writeJob(path: directory.path)

            var listenerPIDs: [Int32] = [123]
            var jobs: [String: Set<Int32>] = [legacy: [123]]
            var starts = 0
            var stoppedLabels: [String] = []
            var failStop = false
            let service = ProjectLifecycleService(
                listeners: { _ in listenerPIDs },
                ownedPIDs: { jobs[$0] ?? [] },
                compatibleLabels: compatible,
                startAgent: { definition in
                    starts += 1
                    jobs[definition.label] = [456]
                    listenerPIDs = [456]
                    return .init(status: 0, output: "")
                },
                stopAgent: { label in
                    stoppedLabels.append(label)
                    if failStop { return .init(status: 1, output: "denied") }
                    listenerPIDs.removeAll { jobs[label]?.contains($0) == true }
                    jobs[label] = nil
                    return .init(status: 0, output: "")
                })
            check(service.state(plan) == .init(running: true), "legacy listener is running without a port conflict")
            check(service.start(plan, timeout: 0).running && starts == 0, "Start does not duplicate the running legacy job")
            failStop = true
            let failure = service.stop(plan, timeout: 0)
            check(failure.running && failure.error?.contains("denied") == true, "failed legacy stop preserves running state and error")
            failStop = false
            stoppedLabels = []
            check(service.stop(plan, timeout: 0) == .init(running: false), "legacy job can be stopped")
            check(stoppedLabels == [legacy], "Stop targets the development job that owns the listener")
            check(service.start(plan, timeout: 0).running && jobs[primary] == [456], "next Start uses the packaged namespace")
            _ = service.stop(plan, timeout: 0)

            listenerPIDs = [789]
            stoppedLabels = []
            let conflict = service.start(plan, timeout: 0)
            check(!conflict.running && conflict.error?.contains("789") == true, "matching plist does not claim an unrelated port listener")
            _ = service.stop(plan, timeout: 0)
            check(stoppedLabels.isEmpty && listenerPIDs == [789], "unrelated listener remains untouched")
            jobs[legacy] = [123]
            listenerPIDs = [123, 789]
            check(service.state(plan).error?.contains("789") == true, "mixed owned and unrelated listeners still report a conflict")
            try writeJob(path: directory.path + "/other")
            listenerPIDs = [123]
            stoppedLabels = []
            _ = service.stop(plan, timeout: 0)
            check(stoppedLabels.isEmpty, "Stop does not control a same-ID job belonging to another folder")
        } catch { check(false, "project lifecycle fixture: \(error)") }
        return (passed, failed)
    }
}
