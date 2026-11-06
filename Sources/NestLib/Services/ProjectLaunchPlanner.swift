import Foundation

public struct ProjectLaunchPlan: Sendable {
    public var projectID: String
    public var projectName: String
    public var port: Int
    public var definition: LaunchAgentDefinition

    public init(
        projectID: String,
        projectName: String,
        port: Int,
        definition: LaunchAgentDefinition
    ) {
        self.projectID = projectID
        self.projectName = projectName
        self.port = port
        self.definition = definition
    }
}

public enum ProjectLaunchPlanner {
    public static func plan(for project: AppProject, launchPath: String = ProjectCommandResolver.launchPath()) -> ProjectLaunchPlan {
        let resolvedCommand = ProjectCommandResolver.resolve(
            command: project.command,
            directory: project.directory,
            port: project.port
        )
        let environment = [
            "PATH": launchPath,
            "PORT": "\(project.port)",
            // Loopback only: a dev server must not be reachable from the local network (public Wi-Fi).
            // cloudflared reaches it on localhost; a project can still opt in with `HOST=0.0.0.0 …`.
            "HOST": ProjectCommandResolver.loopbackHost
        ].merging(resolvedCommand.environmentOverrides) { _, override in override }

        return ProjectLaunchPlan(
            projectID: project.id,
            projectName: project.name,
            port: project.port,
            definition: LaunchAgentDefinition(
                label: project.launchAgentLabel,
                programArguments: resolvedCommand.programArguments,
                workingDirectory: project.directory,
                environment: environment,
                standardOutPath: project.logPath,
                standardErrorPath: project.logPath,
                keepAlive: false
            )
        )
    }

    /// What status checks use (label, port, directory, log), without resolving the command:
    /// that may read and parse package.json, and a refresh runs every few seconds for every
    /// project. The result has no program arguments, so it cannot be launched.
    public static func statusPlan(for project: AppProject) -> ProjectLaunchPlan {
        ProjectLaunchPlan(
            projectID: project.id,
            projectName: project.name,
            port: project.port,
            definition: LaunchAgentDefinition(
                label: project.launchAgentLabel,
                programArguments: [],
                workingDirectory: project.directory,
                environment: ["PORT": "\(project.port)"],
                standardOutPath: project.logPath,
                standardErrorPath: project.logPath,
                keepAlive: false
            )
        )
    }
}
