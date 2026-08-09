/// Reads and writes the Yjs v1 update wire format (structs + delete set) over the
/// `lib0` codec. This is a structural pass: it verifies one complete, bounded
/// update with canonical scalar encodings but does not resolve causal references
/// or integrate structs into a document. `YUpdate.validateV1` exposes that
/// distinction at the public boundary.
enum UpdateCodec {
    private static let maximumClientID = (UInt64(1) << 53) - 1
    private static let maximumClock = UInt64(UInt32.max)

    static func readUpdate(_ bytes: [UInt8]) throws -> ParsedUpdate {
        var decoder = Lib0Decoder(bytes)
        let numClients = try decoder.readBoundedCount()
        var blocks: [ClientBlock] = []
        blocks.reserveCapacity(numClients)
        var seenClients: Set<UInt64> = []
        for _ in 0..<numClients {
            let numStructs = try decoder.readBoundedCount()
            let client = try self.readClient(&decoder)
            guard seenClients.insert(client).inserted else {
                throw Lib0DecodingError.invalidValue
            }
            let firstClock = try self.readClock(&decoder)
            var clock = firstClock
            var structs: [StructRef] = []
            structs.reserveCapacity(numStructs)
            for _ in 0..<numStructs {
                let structRef = try self.readStruct(&decoder, client: client, clock: clock)
                guard structRef.length > 0 else {
                    throw Lib0DecodingError.invalidValue
                }
                let (nextClock, overflow) = clock.addingReportingOverflow(structRef.length)
                guard !overflow, nextClock <= self.maximumClock else {
                    throw Lib0DecodingError.integerOverflow
                }
                clock = nextClock
                structs.append(structRef)
            }
            blocks.append(ClientBlock(client: client, firstClock: firstClock, structs: structs))
        }
        let deleteSet = try self.readDeleteSet(&decoder)
        guard !decoder.hasRemaining else { throw Lib0DecodingError.invalidValue }
        return ParsedUpdate(clientBlocks: blocks, deleteSet: deleteSet)
    }

    static func writeUpdate(_ update: ParsedUpdate) -> [UInt8] {
        var encoder = Lib0Encoder()
        encoder.writeVarUint(UInt64(update.clientBlocks.count))
        for block in update.clientBlocks {
            encoder.writeVarUint(UInt64(block.structs.count))
            encoder.writeVarUint(block.client)
            encoder.writeVarUint(block.firstClock)
            for structRef in block.structs { self.writeStruct(structRef, into: &encoder) }
        }
        self.writeDeleteSet(update.deleteSet, into: &encoder)
        return encoder.bytes
    }

    // MARK: Structs

    private static func readStruct(_ decoder: inout Lib0Decoder, client: UInt64, clock: UInt64) throws -> StructRef {
        let info = try decoder.readUInt8()
        let ref = info & 0x1F
        let id = YID(client: client, clock: clock)
        if info == 0 { return .gc(id: id, length: try self.readClock(&decoder)) }
        if info == 10 { return .skip(id: id, length: try self.readClock(&decoder)) }
        guard ref != 0, ref != 10 else { throw Lib0DecodingError.invalidValue }
        let origin = (info & 0x80) != 0 ? try self.readID(&decoder) : nil
        let rightOrigin = (info & 0x40) != 0 ? try self.readID(&decoder) : nil
        var parent: ParentRef?
        var parentSub: String?
        if (info & 0xC0) == 0 {
            let parentInfo = try decoder.readVarUint()
            guard parentInfo <= 1 else { throw Lib0DecodingError.invalidValue }
            if parentInfo == 1 {
                parent = .rootKey(try decoder.readVarString())
            } else {
                parent = .id(try self.readID(&decoder))
            }
            if (info & 0x20) != 0 { parentSub = try decoder.readVarString() }
        }
        let content = try self.readContent(&decoder, ref: ref)
        return .item(
            ItemRef(
                id: id, info: info, origin: origin, rightOrigin: rightOrigin,
                parent: parent, parentSub: parentSub, content: content
            ))
    }

    private static func writeStruct(_ structRef: StructRef, into encoder: inout Lib0Encoder) {
        switch structRef {
        case .gc(_, let length):
            encoder.writeUInt8(0)
            encoder.writeVarUint(length)
        case .skip(_, let length):
            encoder.writeUInt8(10)
            encoder.writeVarUint(length)
        case .item(let item):
            encoder.writeUInt8(item.info)
            if let origin = item.origin { self.writeID(origin, into: &encoder) }
            if let rightOrigin = item.rightOrigin { self.writeID(rightOrigin, into: &encoder) }
            if (item.info & 0xC0) == 0 {
                switch item.parent {
                case .rootKey(let key):
                    encoder.writeVarUint(1)
                    encoder.writeVarString(key)
                case .id(let parentID):
                    encoder.writeVarUint(0)
                    self.writeID(parentID, into: &encoder)
                case .none:
                    break
                }
                if (item.info & 0x20) != 0, let parentSub = item.parentSub {
                    encoder.writeVarString(parentSub)
                }
            }
            self.writeContent(item.content, into: &encoder)
        }
    }

    // MARK: Content

    private static func readContent(_ decoder: inout Lib0Decoder, ref: UInt8) throws -> ContentRef {
        switch ref {
        case 1: return .deleted(try self.readClock(&decoder))
        case 2:
            let count = try decoder.readBoundedCount()
            var elements: [String] = []
            elements.reserveCapacity(count)
            for _ in 0..<count {
                elements.append(try self.readJSONFragment(&decoder, allowsUndefined: true))
            }
            return .json(elements)
        case 3: return .binary(try decoder.readVarUint8Array())
        case 4: return .string(try decoder.readVarString())
        case 5: return .embed(try self.readJSONFragment(&decoder))
        case 6:
            return .format(
                key: try decoder.readVarString(), value: try self.readJSONFragment(&decoder)
            )
        case 7:
            let typeRef = try decoder.readVarUint()
            guard typeRef <= 6 else { throw Lib0DecodingError.invalidValue }
            let name = (typeRef == 3 || typeRef == 5) ? try decoder.readVarString() : nil
            return .type(ref: typeRef, name: name)
        case 8:
            let count = try decoder.readBoundedCount()
            var elements: [Lib0Any] = []
            for _ in 0..<count { elements.append(try decoder.readAny()) }
            return .any(elements)
        case 9: return .doc(guid: try decoder.readVarString(), options: try decoder.readAny())
        default: throw Lib0DecodingError.invalidAnyTag(ref)
        }
    }

    private static func writeContent(_ content: ContentRef, into encoder: inout Lib0Encoder) {
        switch content {
        case .deleted(let length): encoder.writeVarUint(length)
        case .json(let elements):
            encoder.writeVarUint(UInt64(elements.count))
            for element in elements { encoder.writeVarString(element) }
        case .binary(let bytes): encoder.writeVarUint8Array(bytes)
        case .string(let string): encoder.writeVarString(string)
        case .embed(let json): encoder.writeVarString(json)
        case .format(let key, let value):
            encoder.writeVarString(key)
            encoder.writeVarString(value)
        case .type(let typeRef, let name):
            encoder.writeVarUint(typeRef)
            if let name { encoder.writeVarString(name) }
        case .any(let elements):
            encoder.writeVarUint(UInt64(elements.count))
            for element in elements { encoder.writeAny(element) }
        case .doc(let guid, let options):
            encoder.writeVarString(guid)
            encoder.writeAny(options)
        }
    }

    // MARK: Delete set & IDs

    private static func readDeleteSet(_ decoder: inout Lib0Decoder) throws -> DeleteSetData {
        let numClients = try decoder.readBoundedCount()
        var clients: [DeleteClient] = []
        clients.reserveCapacity(numClients)
        var seenClients: Set<UInt64> = []
        for _ in 0..<numClients {
            let client = try self.readClient(&decoder)
            guard seenClients.insert(client).inserted else {
                throw Lib0DecodingError.invalidValue
            }
            let numRanges = try decoder.readBoundedCount()
            var ranges: [DeleteRange] = []
            ranges.reserveCapacity(numRanges)
            for _ in 0..<numRanges {
                let clock = try self.readClock(&decoder)
                let length = try self.readClock(&decoder)
                guard length > 0 else { throw Lib0DecodingError.invalidValue }
                let (end, overflow) = clock.addingReportingOverflow(length)
                guard !overflow, end <= self.maximumClock else {
                    throw Lib0DecodingError.integerOverflow
                }
                ranges.append(DeleteRange(clock: clock, length: length))
            }
            clients.append(DeleteClient(client: client, ranges: ranges))
        }
        return DeleteSetData(clients: clients)
    }

    private static func writeDeleteSet(_ deleteSet: DeleteSetData, into encoder: inout Lib0Encoder) {
        encoder.writeVarUint(UInt64(deleteSet.clients.count))
        for client in deleteSet.clients {
            encoder.writeVarUint(client.client)
            encoder.writeVarUint(UInt64(client.ranges.count))
            for range in client.ranges {
                encoder.writeVarUint(range.clock)
                encoder.writeVarUint(range.length)
            }
        }
    }

    private static func readID(_ decoder: inout Lib0Decoder) throws -> YID {
        YID(client: try self.readClient(&decoder), clock: try self.readClock(&decoder))
    }

    private static func writeID(_ id: YID, into encoder: inout Lib0Encoder) {
        encoder.writeVarUint(id.client)
        encoder.writeVarUint(id.clock)
    }

    private static func readClient(_ decoder: inout Lib0Decoder) throws -> UInt64 {
        let client = try decoder.readVarUint()
        guard client <= self.maximumClientID else { throw Lib0DecodingError.integerOverflow }
        return client
    }

    private static func readClock(_ decoder: inout Lib0Decoder) throws -> UInt64 {
        let clock = try decoder.readVarUint()
        guard clock <= self.maximumClock else { throw Lib0DecodingError.integerOverflow }
        return clock
    }

    private static func readJSONFragment(
        _ decoder: inout Lib0Decoder, allowsUndefined: Bool = false
    ) throws -> String {
        let value = try decoder.readVarString()
        if allowsUndefined, value == "undefined" { return value }
        do {
            var validator = JSONSyntaxValidator(value)
            try validator.validate()
        } catch {
            throw Lib0DecodingError.invalidValue
        }
        return value
    }
}
