// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "GnarlyNeuralValidation",
    platforms: [.macOS(.v15), .iOS(.v17)],
    products: [.executable(name: "NeuralStemGate", targets: ["NeuralStemGate"])],
    targets: [
        .target(name: "GnarlyNeuralDSP", path: "NightcoreLab/Sources/NeuralStems",
                sources: ["DemucsDSP.swift", "DemucsOverlapAdd.swift", "DemucsCoreMLModel.swift"]),
        .executableTarget(name: "NeuralStemGate", dependencies: ["GnarlyNeuralDSP"],
                          path: "scripts/neural-stems/gate-swift")
    ])
