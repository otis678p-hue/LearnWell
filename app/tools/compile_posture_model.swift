#!/usr/bin/env swift
// Compiles a CoreML .mlpackage into the .mlmodelc bundle Notch Triage ships.
// Xcode does this automatically; this helper keeps Command Line Tools builds working.
//
//   swift tools/compile_posture_model.swift PostureYOLO.mlpackage Sources/PostureYOLO.mlmodelc
import CoreML
import Foundation

guard CommandLine.arguments.count == 3 else {
    print("usage: compile_posture_model.swift <input.mlpackage> <output.mlmodelc>")
    exit(2)
}
let source = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = URL(fileURLWithPath: CommandLine.arguments[2])
do {
    let compiled = try MLModel.compileModel(at: source)
    try? FileManager.default.removeItem(at: destination)
    try FileManager.default.copyItem(at: compiled, to: destination)
    print("compiled \(source.lastPathComponent) -> \(destination.path)")
} catch {
    print("compilation failed: \(error)")
    exit(1)
}
