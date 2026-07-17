import Foundation

public struct BackendEvent: Sendable, Equatable {
    public var name: String
    public var payload: Data

    public init(name: String, payload: Data) {
        self.name = name
        self.payload = payload
    }

    public func decode<T: Decodable>(_ type: T.Type, using decoder: JSONDecoder = JSONDecoder()) throws -> T {
        try decoder.decode(type, from: payload)
    }
}

public enum BackendTransportError: LocalizedError, Equatable {
    case runtimeCreation(String)
    case invalidArguments(String)
    case invalidResponse(String)
    case backend(String)

    public var errorDescription: String? {
        switch self {
        case let .runtimeCreation(message), let .invalidArguments(message),
             let .invalidResponse(message), let .backend(message): message
        }
    }
}

public protocol BackendDispatching: Sendable {
    func request(_ command: String, arguments: [String: AnySendable]) async throws -> Data
    func setEventHandler(_ handler: (@Sendable (BackendEvent) -> Void)?)
}

/// A small JSON-compatible value wrapper used to keep the command boundary
/// explicit and Sendable without leaking Foundation's untyped NSDictionary API.
public enum AnySendable: Sendable, Equatable {
    case string(String)
    case bool(Bool)
    case number(Double)
    case object([String: AnySendable])
    case array([AnySendable])
    case null

    public static func encodable<T: Encodable>(_ value: T) throws -> AnySendable {
        let data = try JSONEncoder().encode(value)
        let object = try JSONSerialization.jsonObject(with: data)
        return try from(object)
    }

    public static func from(_ value: Any) throws -> AnySendable {
        switch value {
        case let value as String: .string(value)
        case let value as Bool: .bool(value)
        case let value as NSNumber: .number(value.doubleValue)
        case let value as [Any]: .array(try value.map(from))
        case let value as [String: Any]: .object(try value.mapValues(from))
        case is NSNull: .null
        default:
            throw BackendTransportError.invalidArguments(
                "unsupported JSON argument type: \(type(of: value))"
            )
        }
    }

    fileprivate var foundationValue: Any {
        switch self {
        case let .string(value): value
        case let .bool(value): value
        case let .number(value): value
        case let .object(value): value.mapValues(\.foundationValue)
        case let .array(value): value.map(\.foundationValue)
        case .null: NSNull()
        }
    }
}

public struct BackendRuntimeConfiguration: Codable, Sendable, Equatable {
    public var resourceDir: String?
    public var appDataDir: String?
    public var nativeDir: String?
    public var homeDir: String?

    public init(
        resourceDir: String? = nil,
        appDataDir: String? = nil,
        nativeDir: String? = nil,
        homeDir: String? = nil
    ) {
        self.resourceDir = resourceDir
        self.appDataDir = appDataDir
        self.nativeDir = nativeDir
        self.homeDir = homeDir
    }

    public static var bundled: BackendRuntimeConfiguration {
        let resources = Bundle.main.resourceURL?.path
        return BackendRuntimeConfiguration(
            resourceDir: resources,
            nativeDir: Bundle.main.resourceURL?.appendingPathComponent("native").path
        )
    }
}

private typealias ArcoRuntimePointer = UnsafeMutableRawPointer
private typealias ArcoEventFunction = @convention(c) (
    UnsafePointer<CChar>?,
    UnsafePointer<CChar>?,
    UnsafeMutableRawPointer?
) -> Void

@_silgen_name("arco_runtime_create")
private func arcoRuntimeCreate(
    _ configJSON: UnsafePointer<CChar>,
    _ callback: ArcoEventFunction?,
    _ context: UnsafeMutableRawPointer?
) -> ArcoRuntimePointer?

@_silgen_name("arco_runtime_dispatch")
private func arcoRuntimeDispatch(
    _ runtime: ArcoRuntimePointer,
    _ command: UnsafePointer<CChar>,
    _ argumentsJSON: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("arco_runtime_destroy")
private func arcoRuntimeDestroy(_ runtime: ArcoRuntimePointer)

@_silgen_name("arco_string_free")
private func arcoStringFree(_ value: UnsafeMutablePointer<CChar>)

@_silgen_name("arco_last_error_message")
private func arcoLastErrorMessage() -> UnsafePointer<CChar>?

private let arcoEventFunction: ArcoEventFunction = { name, payload, context in
    guard let name, let payload, let context else { return }
    let transport = Unmanaged<RustBackendTransport>.fromOpaque(context).takeUnretainedValue()
    transport.receiveEvent(
        name: String(cString: name),
        payload: Data(String(cString: payload).utf8)
    )
}

public final class RustBackendTransport: BackendDispatching, @unchecked Sendable {
    private var runtime: ArcoRuntimePointer?
    private let runtimeCondition = NSCondition()
    private var activeRequests = 0
    private var shuttingDown = false
    private let handlerLock = NSLock()
    private var eventHandler: (@Sendable (BackendEvent) -> Void)?

    private init() {}

    public static func create(
        configuration: BackendRuntimeConfiguration = .bundled
    ) throws -> RustBackendTransport {
        let transport = RustBackendTransport()
        let config = try JSONEncoder().encode(configuration)
        guard let configJSON = String(data: config, encoding: .utf8) else {
            throw BackendTransportError.runtimeCreation("could not encode backend configuration")
        }
        let context = Unmanaged.passUnretained(transport).toOpaque()
        let runtime = configJSON.withCString {
            arcoRuntimeCreate($0, arcoEventFunction, context)
        }
        guard let runtime else {
            let message = arcoLastErrorMessage().map(String.init(cString:))
                ?? "Arco backend runtime could not be created"
            throw BackendTransportError.runtimeCreation(message)
        }
        transport.runtime = runtime
        return transport
    }

    deinit { shutdown() }

    /// Synchronously closes the embedded Rust runtime after every in-flight
    /// dispatch has returned. AppKit does not guarantee enough teardown time
    /// after `applicationWillTerminate` for relying on property destruction
    /// alone, and the Rust capture owner must finalize an active transcript.
    public func shutdown() {
        setEventHandler(nil)
        runtimeCondition.lock()
        shuttingDown = true
        while activeRequests > 0 {
            runtimeCondition.wait()
        }
        let runtimeToDestroy = runtime
        runtime = nil
        runtimeCondition.unlock()
        if let runtimeToDestroy {
            arcoRuntimeDestroy(runtimeToDestroy)
        }
    }

    public func setEventHandler(_ handler: (@Sendable (BackendEvent) -> Void)?) {
        handlerLock.lock()
        eventHandler = handler
        handlerLock.unlock()
    }

    fileprivate func receiveEvent(name: String, payload: Data) {
        handlerLock.lock()
        let handler = eventHandler
        handlerLock.unlock()
        handler?(BackendEvent(name: name, payload: payload))
    }

    public func request(
        _ command: String,
        arguments: [String: AnySendable] = [:]
    ) async throws -> Data {
        let object = arguments.mapValues(\.foundationValue)
        guard JSONSerialization.isValidJSONObject(object) else {
            throw BackendTransportError.invalidArguments("backend arguments are not valid JSON")
        }
        let argumentsData = try JSONSerialization.data(withJSONObject: object)
        guard let argumentsJSON = String(data: argumentsData, encoding: .utf8) else {
            throw BackendTransportError.invalidArguments("backend arguments are not UTF-8")
        }

        let runtime = try beginRequest()
        defer { finishRequest() }
        return try await Task.detached(priority: .userInitiated) {
            let raw = command.withCString { commandPointer in
                argumentsJSON.withCString { argumentsPointer in
                    arcoRuntimeDispatch(runtime, commandPointer, argumentsPointer)
                }
            }
            guard let raw else {
                throw BackendTransportError.invalidResponse("backend returned no response")
            }
            defer { arcoStringFree(raw) }
            let data = Data(String(cString: raw).utf8)
            guard
                let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let ok = envelope["ok"] as? Bool
            else {
                throw BackendTransportError.invalidResponse("backend returned an invalid envelope")
            }
            if !ok {
                throw BackendTransportError.backend(
                    envelope["error"] as? String ?? "backend command failed"
                )
            }
            let result = envelope["result"] ?? NSNull()
            return try JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed])
        }.value
    }

    private func beginRequest() throws -> ArcoRuntimePointer {
        runtimeCondition.lock()
        defer { runtimeCondition.unlock() }
        guard !shuttingDown, let runtime else {
            throw BackendTransportError.backend("Arco backend runtime is not available")
        }
        activeRequests += 1
        return runtime
    }

    private func finishRequest() {
        runtimeCondition.lock()
        activeRequests -= 1
        if activeRequests == 0 {
            runtimeCondition.broadcast()
        }
        runtimeCondition.unlock()
    }
}

public extension BackendDispatching {
    func call<T: Decodable>(
        _ command: String,
        arguments: [String: AnySendable] = [:],
        as type: T.Type = T.self,
        decoder: JSONDecoder = JSONDecoder()
    ) async throws -> T {
        let data = try await request(command, arguments: arguments)
        return try decoder.decode(T.self, from: data)
    }

    func callVoid(_ command: String, arguments: [String: AnySendable] = [:]) async throws {
        _ = try await request(command, arguments: arguments)
    }

    func callDecodedOffMain<T: Decodable & Sendable>(
        _ command: String,
        arguments: [String: AnySendable] = [:],
        as type: T.Type = T.self
    ) async throws -> T {
        let data = try await request(command, arguments: arguments)
        return try await Task.detached(priority: .userInitiated) {
            try JSONDecoder().decode(T.self, from: data)
        }.value
    }
}
