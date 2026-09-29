// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Sessions",
    platforms: [.macOS(.v14)],
    targets: [
        // Общий код: протокол обмена между приложением и хуками
        .target(name: "SessionsCore"),
        .testTarget(name: "SessionsCoreTests", dependencies: ["SessionsCore"]),

        // Telegram-бот и режим «Я отошёл»: только Foundation, тестируется без сети
        .target(name: "SessionsTelegram"),
        .testTarget(name: "SessionsTelegramTests", dependencies: ["SessionsTelegram"]),

        // Инвентарь MCP / плагинов / скиллов: только Foundation, тестируется отдельно
        .target(name: "SessionsInventory"),
        .testTarget(name: "SessionsInventoryTests", dependencies: ["SessionsInventory"]),

        // Крошечный CLI, который вызывается из хуков Claude Code
        .executableTarget(
            name: "sessions-cli",
            dependencies: ["SessionsCore"],
            path: "Sources/SessionsCLI"
        ),

        // Само приложение в строке меню
        .executableTarget(
            name: "SessionsApp",
            dependencies: ["SessionsCore", "SessionsInventory", "SessionsTelegram"],
            path: "Sources/SessionsApp"
        )
    ]
)
