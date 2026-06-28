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
            "HOST": "0.0.0.0"
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
}
