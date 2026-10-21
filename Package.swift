// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "GnarlyNeuralValidation",
    platforms: [.macOS("15.0"), .iOS(.v17)],
    products: [.executable(name: "NeuralStemGate", targets: ["NeuralStemGate"])],
    targets: [
        .target(name: "GnarlyNeuralDSP", path: "NightcoreLab/Sources/NeuralStems",
                exclude: ["NeuralStemWorker.swift", "StemGainAudioUnit.swift"],
                sources: ["DemucsDSP.swift", "DemucsOverlapAdd.swift", "DemucsCoreMLModel.swift", "BlockedAttention.swift", "StagedDemucsPipeline.swift", "StemMemoryRecovery.swift"]),
        .executableTarget(name: "NeuralStemGate", dependencies: ["GnarlyNeuralDSP"],
                          path: "scripts/neural-stems/gate-swift"),
        .testTarget(name: "GnarlyNeuralDSPTests", dependencies: ["GnarlyNeuralDSP"],
                    path: "NightcoreLabTests", sources: ["DemucsDSPTests.swift", "BlockedAttentionTests.swift", "StemMemoryRecoveryTests.swift"])
    ])
