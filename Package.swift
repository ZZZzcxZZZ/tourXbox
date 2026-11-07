// swift-tools-version: 6.0
import PackageDescription
var products:[Product] = [.library(name:"MappingCore",targets:["MappingCore"])]
var targets:[Target] = [.target(name:"MappingCore"),.testTarget(name:"MappingCoreTests",dependencies:["MappingCore"])]
#if os(macOS)
products.append(.executable(name:"tourXbox",targets:["BrushPad"]))
targets.append(.executableTarget(name:"BrushPad",dependencies:["MappingCore"],exclude:["Assets.xcassets"],resources:[.copy("Resources")]))
targets.append(.testTarget(name:"BrushPadRuntimeTests",dependencies:["BrushPad"]))
#endif
let package=Package(name:"tourXbox",platforms:[.macOS(.v14)],products:products,targets:targets,swiftLanguageModes:[.v5])
