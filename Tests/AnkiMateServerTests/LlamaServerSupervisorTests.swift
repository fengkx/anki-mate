import XCTest
@testable import AnkiMateServer

final class LlamaServerSupervisorTests: XCTestCase {

    func testInitialStateIsStopped() {
        let supervisor = LlamaServerSupervisor(childPort: 9999)

        XCTAssertEqual(supervisor.state, .stopped)
        XCTAssertNil(supervisor.loadedModelPath)
        XCTAssertNil(supervisor.childPort)
    }

    func testStateReadyProvidesPortAndModelPath() {
        let state = LlamaServerState.ready(port: 8081, modelPath: "/test.gguf")

        XCTAssertTrue(state.isReady)
        XCTAssertEqual(state.port, 8081)
        XCTAssertEqual(state.modelPath, "/test.gguf")
    }

    func testStateStoppedHasNoPortOrPath() {
        let state = LlamaServerState.stopped

        XCTAssertFalse(state.isReady)
        XCTAssertNil(state.port)
        XCTAssertNil(state.modelPath)
    }

    func testStateFailedHasNoPortOrPath() {
        let state = LlamaServerState.failed("crash")

        XCTAssertFalse(state.isReady)
        XCTAssertNil(state.port)
        XCTAssertNil(state.modelPath)
    }

    func testStateEquality() {
        XCTAssertEqual(LlamaServerState.stopped, LlamaServerState.stopped)
        XCTAssertEqual(LlamaServerState.starting, LlamaServerState.starting)
        XCTAssertEqual(
            LlamaServerState.ready(port: 1, modelPath: "a"),
            LlamaServerState.ready(port: 1, modelPath: "a")
        )
        XCTAssertNotEqual(
            LlamaServerState.ready(port: 1, modelPath: "a"),
            LlamaServerState.ready(port: 2, modelPath: "a")
        )
        XCTAssertEqual(
            LlamaServerState.failed("x"),
            LlamaServerState.failed("x")
        )
    }

    func testLaunchArgumentsDisableReasoningByDefault() {
        XCTAssertEqual(
            LlamaServerSupervisor.launchArguments(
                port: 8080,
                modelPath: "/tmp/model.gguf",
                contextSize: 4096,
                gpuLayers: 99
            ),
            [
                "--host", "127.0.0.1",
                "--port", "8080",
                "--jinja",
                "--no-webui",
                "--reasoning", "off",
                "--flash-attn", "on",
                "-m", "/tmp/model.gguf",
                "-c", "4096",
                "-ngl", "99",
            ]
        )
    }

    func testLaunchArgumentsIncludeMMProjWhenProvided() {
        XCTAssertTrue(
            LlamaServerSupervisor.launchArguments(
                port: 8080,
                modelPath: "/tmp/model.gguf",
                mmprojPath: "/tmp/mmproj-F16.gguf",
                contextSize: 4096,
                gpuLayers: 99
            )
            .suffix(2)
            .elementsEqual(["--mmproj", "/tmp/mmproj-F16.gguf"])
        )
    }
}
