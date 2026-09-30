import Foundation
import Testing
@testable import SiliconElevenLabs
@testable import SiliconUI

/// The voices-and-studio sections against the pinned spec: every control sets an argument
/// the operation really takes, every value offered in prose is in the spec's prose, every
/// enum picker still has values, and every operation of these sections is either reached from
/// a screen or left to the Explorer with a reason.
@Suite("ElevenLabs voices and studio sections against the spec")
@MainActor
struct VoicesStudioSpecTests {

    @Test func everyControlSetsAnArgumentOfARealOperation() {
        #expect(!VoicesStudioCoverage.controls.isEmpty)
        for control in VoicesStudioCoverage.controls {
            #expect(ElevenLabsCatalog.operation(control.operationID) != nil, "\(control): no such operation")
            #expect(VoicesStudioSchema.has(control.operationID, control.argument), "\(control): no such argument")
        }
    }

    @Test func everyValueOfferedInProseIsInTheArgumentsDescription() {
        for control in VoicesStudioCoverage.controls where !control.describedValues.isEmpty {
            let description = VoicesStudioSchema.description(control.operationID, control.argument).lowercased()
            for value in control.describedValues {
                #expect(description.contains(value.lowercased()), "\(control) does not mention \(value)")
            }
        }
    }

    @Test func everyEnumPickerStillHasValuesInTheSpec() {
        for control in VoicesStudioCoverage.controls where control.enumerated {
            #expect(!VoicesStudioSchema.choices(control.operationID, control.argument).isEmpty, "\(control)")
        }
    }

    @Test func everyOperationOfTheseSectionsIsReachedOrLeftToTheExplorerWithAReason() {
        let mine = Set(VoicesStudioCoverage.entries.map(\.section))
        let operations = ElevenLabsCatalog.all.filter { operation in
            ElevenLabsSection.section(for: operation).map(mine.contains) ?? false
        }
        #expect(!operations.isEmpty)
        let native = VoicesStudioCoverage.native
        let explorer = VoicesStudioCoverage.explorerOnly
        for operation in operations {
            let placed = native.contains(operation.id) || explorer[operation.id] != nil
            #expect(placed, "\(operation.id) (\(operation.method) \(operation.path)) is neither on a screen nor left to the Explorer")
        }
        #expect(native.isDisjoint(with: explorer.keys), "an operation cannot be both native and Explorer-only")
        let ids = Set(operations.map(\.id))
        for id in explorer.keys {
            #expect(ids.contains(id), "\(id) is left to the Explorer but is not an operation of these sections")
            #expect(!(explorer[id] ?? "").isEmpty)
        }
        for id in native {
            #expect(ElevenLabsCatalog.operation(id) != nil, "\(id) is not in the catalog")
        }
    }

    @Test func theSchemaReaderFindsNestedFieldsAndUnionItems() {
        #expect(VoicesStudioSchema.has("dubbing_language_create", "voice_settings.cloning_strength"))
        #expect(VoicesStudioSchema.range("dubbing_language_create", "voice_settings.cloning_strength") == 0...10)
        #expect(!VoicesStudioSchema.has("dubbing_language_create", "voice_settings.nonsense"))
        #expect(VoicesStudioSchema.choices("dubbing_project_create", "model_id").contains("dubbing_v2"))
        #expect(VoicesStudioSchema.minLength("text_to_voice_design", "voice_description") == 20)
        #expect(!VoicesStudioSchema.has("no_such_operation", "x"))
        #expect(VoicesStudioSchema.choices("public_list_orders", "status").contains("submitted"),
                "a multi-select filter offers its items' values")
    }
}
