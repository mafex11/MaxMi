import XCTest
@testable import MaxMi
import MaxMiActivity

final class StoreAgentRepositoryTests: XCTestCase {

    func testValidateCreate() throws {
        let dtos = [
            AgentOpDTO(op: "create", id: nil, kind: "todo", title: "Test task", details: "Details here", evidence: nil, sourceRefs: ["s1"])
        ]

        let ops = try StoreAgentRepository.validateAndMap(dtos)

        XCTAssertEqual(ops.count, 1)
        if case .create(let kind, let title, let details, let sourceRefs) = ops[0] {
            XCTAssertEqual(kind, "todo")
            XCTAssertEqual(title, "Test task")
            XCTAssertEqual(details, "Details here")
            XCTAssertEqual(sourceRefs, ["s1"])
        } else {
            XCTFail("Expected create op")
        }
    }

    func testValidateUpdate() throws {
        let dtos = [
            AgentOpDTO(op: "update", id: "item1", kind: nil, title: "Updated title", details: nil, evidence: nil, sourceRefs: nil)
        ]

        let ops = try StoreAgentRepository.validateAndMap(dtos)

        XCTAssertEqual(ops.count, 1)
        if case .update(let id, let title, let details) = ops[0] {
            XCTAssertEqual(id, "item1")
            XCTAssertEqual(title, "Updated title")
            XCTAssertNil(details)
        } else {
            XCTFail("Expected update op")
        }
    }

    func testValidateResolve() throws {
        let dtos = [
            AgentOpDTO(op: "resolve", id: "item1", kind: nil, title: nil, details: nil, evidence: "Task completed successfully", sourceRefs: nil)
        ]

        let ops = try StoreAgentRepository.validateAndMap(dtos)

        XCTAssertEqual(ops.count, 1)
        if case .resolve(let id, let evidence) = ops[0] {
            XCTAssertEqual(id, "item1")
            XCTAssertEqual(evidence, "Task completed successfully")
        } else {
            XCTFail("Expected resolve op")
        }
    }

    func testRejectUnknownOp() {
        let dtos = [
            AgentOpDTO(op: "delete", id: "item1", kind: nil, title: nil, details: nil, evidence: nil, sourceRefs: nil)
        ]

        XCTAssertThrowsError(try StoreAgentRepository.validateAndMap(dtos)) { error in
            XCTAssertTrue(error is StoreAgentRepository.ValidationError)
            if let validationError = error as? StoreAgentRepository.ValidationError {
                if case .unknownOp(let msg) = validationError {
                    XCTAssertTrue(msg.contains("delete"))
                } else {
                    XCTFail("Expected unknownOp error")
                }
            }
        }
    }

    func testRejectCreateMissingKind() {
        let dtos = [
            AgentOpDTO(op: "create", id: nil, kind: nil, title: "Test", details: nil, evidence: nil, sourceRefs: nil)
        ]

        XCTAssertThrowsError(try StoreAgentRepository.validateAndMap(dtos)) { error in
            XCTAssertTrue(error is StoreAgentRepository.ValidationError)
        }
    }

    func testRejectCreateMissingTitle() {
        let dtos = [
            AgentOpDTO(op: "create", id: nil, kind: "todo", title: nil, details: nil, evidence: nil, sourceRefs: nil)
        ]

        XCTAssertThrowsError(try StoreAgentRepository.validateAndMap(dtos)) { error in
            XCTAssertTrue(error is StoreAgentRepository.ValidationError)
        }
    }

    func testRejectCreateEmptyTitle() {
        let dtos = [
            AgentOpDTO(op: "create", id: nil, kind: "todo", title: "", details: nil, evidence: nil, sourceRefs: nil)
        ]

        XCTAssertThrowsError(try StoreAgentRepository.validateAndMap(dtos)) { error in
            XCTAssertTrue(error is StoreAgentRepository.ValidationError)
        }
    }

    func testRejectUpdateMissingID() {
        let dtos = [
            AgentOpDTO(op: "update", id: nil, kind: nil, title: "Test", details: nil, evidence: nil, sourceRefs: nil)
        ]

        XCTAssertThrowsError(try StoreAgentRepository.validateAndMap(dtos)) { error in
            XCTAssertTrue(error is StoreAgentRepository.ValidationError)
        }
    }

    func testRejectUpdateNoFields() {
        let dtos = [
            AgentOpDTO(op: "update", id: "item1", kind: nil, title: nil, details: nil, evidence: nil, sourceRefs: nil)
        ]

        XCTAssertThrowsError(try StoreAgentRepository.validateAndMap(dtos)) { error in
            XCTAssertTrue(error is StoreAgentRepository.ValidationError)
        }
    }

    func testRejectResolveMissingID() {
        let dtos = [
            AgentOpDTO(op: "resolve", id: nil, kind: nil, title: nil, details: nil, evidence: "Done", sourceRefs: nil)
        ]

        XCTAssertThrowsError(try StoreAgentRepository.validateAndMap(dtos)) { error in
            XCTAssertTrue(error is StoreAgentRepository.ValidationError)
        }
    }

    func testRejectResolveMissingEvidence() {
        let dtos = [
            AgentOpDTO(op: "resolve", id: "item1", kind: nil, title: nil, details: nil, evidence: nil, sourceRefs: nil)
        ]

        XCTAssertThrowsError(try StoreAgentRepository.validateAndMap(dtos)) { error in
            XCTAssertTrue(error is StoreAgentRepository.ValidationError)
        }
    }

    func testRejectTitleTooLong() {
        let longTitle = String(repeating: "a", count: 501)
        let dtos = [
            AgentOpDTO(op: "create", id: nil, kind: "todo", title: longTitle, details: nil, evidence: nil, sourceRefs: nil)
        ]

        XCTAssertThrowsError(try StoreAgentRepository.validateAndMap(dtos)) { error in
            XCTAssertTrue(error is StoreAgentRepository.ValidationError)
        }
    }

    func testRejectDetailsTooLong() {
        let longDetails = String(repeating: "a", count: 2001)
        let dtos = [
            AgentOpDTO(op: "create", id: nil, kind: "todo", title: "Test", details: longDetails, evidence: nil, sourceRefs: nil)
        ]

        XCTAssertThrowsError(try StoreAgentRepository.validateAndMap(dtos)) { error in
            XCTAssertTrue(error is StoreAgentRepository.ValidationError)
        }
    }

    func testRejectEvidenceTooLong() {
        let longEvidence = String(repeating: "a", count: 2001)
        let dtos = [
            AgentOpDTO(op: "resolve", id: "item1", kind: nil, title: nil, details: nil, evidence: longEvidence, sourceRefs: nil)
        ]

        XCTAssertThrowsError(try StoreAgentRepository.validateAndMap(dtos)) { error in
            XCTAssertTrue(error is StoreAgentRepository.ValidationError)
        }
    }

    func testEmptyStringFieldsTreatedAsNil() throws {
        let dtos = [
            AgentOpDTO(op: "create", id: nil, kind: "todo", title: "Test", details: "", evidence: nil, sourceRefs: [])
        ]

        let ops = try StoreAgentRepository.validateAndMap(dtos)

        if case .create(_, _, let details, let sourceRefs) = ops[0] {
            XCTAssertNil(details)
            XCTAssertEqual(sourceRefs, [])
        } else {
            XCTFail("Expected create op")
        }
    }

    func testMultipleOps() throws {
        let dtos = [
            AgentOpDTO(op: "create", id: nil, kind: "todo", title: "New task", details: nil, evidence: nil, sourceRefs: ["s1"]),
            AgentOpDTO(op: "update", id: "item1", kind: nil, title: "Updated", details: nil, evidence: nil, sourceRefs: nil),
            AgentOpDTO(op: "resolve", id: "item2", kind: nil, title: nil, details: nil, evidence: "Done", sourceRefs: nil)
        ]

        let ops = try StoreAgentRepository.validateAndMap(dtos)
        XCTAssertEqual(ops.count, 3)
    }
}
