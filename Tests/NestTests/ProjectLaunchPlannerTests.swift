import Foundation
import NestLib

enum ProjectLaunchPlannerTests {
    static func runAll() -> (passed: Int, failed: Int) {
        var passed = 0
        var failed = 0

        func assert(_ condition: Bool, _ msg: String, file: String = #file, line: Int = #line) {
            if condition {
                passed += 1
            } else {
                failed += 1
                print("  FAIL: \(msg) (\(file):\(line))")
            }
        }

        let project = AppProject(
            id: "my-app",
            name: "My App",
            hostname: "my-app.test",
            directory: "/Users/test/my-app",
            port: 3999,
            command: "NODE_ENV=production bun run start"
        )
        let plan = ProjectLaunchPlanner.plan(for: project, launchPath: "/custom/bin:/usr/bin")

        assert(plan.projectID == "my-app", "should preserve project id")
        assert(plan.projectName == "My App", "should preserve project name")
        assert(plan.port == 3999, "should preserve port")
        assert(plan.definition.label == project.launchAgentLabel, "should use project launch agent label")
        assert(plan.definition.workingDirectory == "/Users/test/my-app", "should set working directory")
        assert(plan.definition.programArguments == ["/usr/bin/env", "bun", "run", "start"], "should build direct command")
        assert(plan.definition.environment["PATH"] == "/custom/bin:/usr/bin", "should set launch path")
        assert(plan.definition.environment["PORT"] == "3999", "should set port environment")
        assert(plan.definition.environment["HOST"] == "0.0.0.0", "should set host environment")
        assert(plan.definition.environment["NODE_ENV"] == "production", "should merge command environment")
        assert(plan.definition.keepAlive == false, "project launch agents should not keep alive")

        return (passed, failed)
    }
}
