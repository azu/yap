import ArgumentParser

// MARK: - chronixd-capture

@main struct ChronixdCaptureCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "chronixd-capture",
        abstract: "A CLI for screen context capture and querying.",
        subcommands: [
            Cameras.self,
            Capture.self,
            Context.self,
            Speakers.self,
            Snapshot.self,
        ],
        defaultSubcommand: Capture.self
    )
}
