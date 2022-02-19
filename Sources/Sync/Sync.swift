
import Foundation
import Combine

public protocol SyncedObject: AnyObject, Codable { }

public class SyncManager<Value: SyncedObject> {
    enum SyncManagerError: Error {
        case unretainedValueWasReleased
    }

    private class BaseStorage {
        var object: Value? {
            return nil
        }
    }

    private final class RetainedStorage: BaseStorage {
        let value: Value

        init(value: Value) {
            self.value = value
        }

        override var object: Value? {
            return value
        }
    }

    private final class WeakStorage: BaseStorage {
        weak var value: Value?

        init(value: Value) {
            self.value = value
        }

        override var object: Value? {
            return value
        }
    }

    private let strategy: AnySyncStrategy<Value>
    private let storage: BaseStorage
    public let connection: Connection
    private var cancellables: Set<AnyCancellable> = []
    private let errorsSubject = PassthroughSubject<Error, Never>()
    private let hasChangedSubject = PassthroughSubject<Void, Never>()

    public var isConnected: Bool {
        return connection.isConnected
    }

    public var eventHasChanged: AnyPublisher<Void, Never> {
        return hasChangedSubject.eraseToAnyPublisher()
    }

    init(_ value: Value, connection: Connection) {
        self.strategy = extractStrategy(for: Value.self)
        self.storage = RetainedStorage(value: value)
        self.connection = connection
        setUpConnection()
    }

    init(weak value: Value, connection: Connection) {
        self.strategy = extractStrategy(for: Value.self)
        self.storage = WeakStorage(value: value)
        self.connection = connection
        setUpConnection()
    }

    public func value() throws -> Value {
        guard let value = storage.object else {
            throw SyncManagerError.unretainedValueWasReleased
        }
        return value
    }

    public func data() throws -> Data {
        return try connection.codingContext.encode(try value())
    }

    private func setUpConnection() {
        cancellables = []
        connection
            .receive()
            .sink { [unowned self] data in
                do {
                    var value = try self.value()
                    let event = try self.connection.codingContext.decode(data: data, as: InternalEvent.self)
                    try self.strategy.handle(event: event, with: self.connection.codingContext, for: &value)
                    self.hasChangedSubject.send()
                } catch {
                    self.errorsSubject.send(error)
                }
            }
            .store(in: &cancellables)

        guard let value = storage.object else { return }
        strategy
            .events(for: Just(value).eraseToAnyPublisher(),
                    with: connection.codingContext)
            .sink { [unowned self] event in
                do {
                    self.hasChangedSubject.send()
                    let data = try self.connection.codingContext.encode(event)
                    self.connection.send(data: data)
                } catch {
                    self.errorsSubject.send(error)
                }
            }
            .store(in: &cancellables)
    }
}

extension SyncedObject {
    public func manager(with connection: ProducerConnection) -> SyncManager<Self> {
        return SyncManager(self, connection: connection)
    }

    public func managerWithoutRetainingInMemory(with connection: ProducerConnection) -> SyncManager<Self> {
        return SyncManager(weak: self, connection: connection)
    }

    public static func manager(with connection: ConsumerConnection) async throws -> SyncManager<Self> {
        let data = try await connection.connect()
        let value = try connection.codingContext.decode(data: data, as: Self.self)
        return SyncManager(value, connection: connection)
    }
}
