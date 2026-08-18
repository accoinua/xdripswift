import Foundation
import JavaScriptCore

/// Serial JavaScriptCore bridge to the generated managed port of the Chinese
/// SIBIONICS GS1 v1.1.5G stock algorithm.
final class SibionicsV115GAlgorithm {
    enum AlgorithmError: LocalizedError {
        case resourceMissing
        case scriptLoadFailed(String)
        case apiMissing

        var errorDescription: String? {
            switch self {
            case .resourceMissing:
                return "The bundled SIBIONICS v1.1.5G algorithm is missing."
            case .scriptLoadFailed(let reason):
                return "The SIBIONICS v1.1.5G algorithm could not be loaded: \(reason)"
            case .apiMissing:
                return "The bundled SIBIONICS v1.1.5G API is invalid."
            }
        }
    }

    private let queue = DispatchQueue(label: "xdrip.sibionics.v115g")
    private var context: JSContext?
    private var api: JSValue?
    private var lastException: String?

    init(sensitivity: Double) throws {
        var initializationError: Error?
        queue.sync {
            do {
                guard let url = Bundle.main.url(forResource: "sibionics-v115g", withExtension: "js") else {
                    throw AlgorithmError.resourceMissing
                }
                let source = try String(contentsOf: url, encoding: .utf8)
                guard let context = JSContext() else { throw AlgorithmError.apiMissing }
                context.exceptionHandler = { [weak self] _, exception in
                    self?.lastException = exception?.toString()
                }
                self.context = context
                context.evaluateScript(source, withSourceURL: url)
                if let exception = lastException {
                    throw AlgorithmError.scriptLoadFailed(exception)
                }
                let root = context.objectForKeyedSubscript("sibionics-v115g-js")
                let api = root?
                    .forProperty("tk")?
                    .forProperty("glucodata")?
                    .forProperty("drivers")?
                    .forProperty("sibionics")?
                    .forProperty("SibionicsV115G")
                guard let api = api, !api.isUndefined, !api.isNull else {
                    throw AlgorithmError.apiMissing
                }
                self.api = api
                lastException = nil
                api.invokeMethod("reset", withArguments: [sensitivity])
                if let exception = lastException {
                    throw AlgorithmError.scriptLoadFailed(exception)
                }
            } catch {
                initializationError = error
            }
        }
        if let initializationError = initializationError { throw initializationError }
    }

    /// Returns stock mmol/L with the native five-sample correction carried over
    /// to intervening one-minute samples. Nil means the embedded algorithm failed.
    func process(rawMmol: Double, temperatureC: Double, index: Int, live: Bool) -> Double? {
        queue.sync {
            lastException = nil
            guard let value = api?.invokeMethod(
                "process",
                withArguments: [rawMmol, temperatureC, index, live]
            ), lastException == nil, value.isNumber else { return nil }
            let output = value.toDouble()
            return output.isFinite && output > 0 && output <= 35 ? output : nil
        }
    }

    func snapshot() -> String? {
        queue.sync {
            lastException = nil
            guard let value = api?.invokeMethod("snapshotHex", withArguments: []),
                  lastException == nil,
                  value.isString else { return nil }
            return value.toString()
        }
    }

    func restore(snapshot: String) -> Bool {
        queue.sync {
            lastException = nil
            guard let value = api?.invokeMethod("restoreHex", withArguments: [snapshot]),
                  lastException == nil else { return false }
            return value.toBool()
        }
    }
}
