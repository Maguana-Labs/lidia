import CoreData
import Foundation
import SwiftData

/// Checks a SwiftData schema against CloudKit's rules and describes it field by field.
///
/// Used by the tests on both sides (LidIAKit and the Mac app). It walks the Core Data
/// model SwiftData builds, which is what `NSPersistentCloudKitContainer` validates and
/// maps to CloudKit record types.
public enum LidIASchemaAudit {
    /// The Core Data model SwiftData builds for `types`.
    public static func managedObjectModel(for types: [any PersistentModel.Type]) -> NSManagedObjectModel? {
        NSManagedObjectModel.makeManagedObjectModel(for: types)
    }

    /// Every way `model` breaks CloudKit's rules, as readable lines. Empty means compatible.
    ///
    /// - every attribute is optional or has a default value;
    /// - every relationship is optional, has an inverse, and is not ordered;
    /// - no unique constraints;
    /// - no `Deny` delete rule (CloudKit can't enforce it across devices).
    public static func cloudKitViolations(in model: NSManagedObjectModel) -> [String] {
        var problems: [String] = []
        for entity in model.entities.sorted(by: { ($0.name ?? "") < ($1.name ?? "") }) {
            let name = entity.name ?? "?"
            if !entity.uniquenessConstraints.isEmpty {
                problems.append("\(name): unique constraint \(entity.uniquenessConstraints)")
            }
            for (key, property) in entity.propertiesByName.sorted(by: { $0.key < $1.key }) {
                if let attribute = property as? NSAttributeDescription {
                    if attribute.isTransient { continue }
                    if !attribute.isOptional && attribute.defaultValue == nil {
                        problems.append("\(name).\(key): non-optional attribute without a default value")
                    }
                } else if let relationship = property as? NSRelationshipDescription {
                    if !relationship.isOptional {
                        problems.append("\(name).\(key): relationship must be optional")
                    }
                    if relationship.inverseRelationship == nil {
                        problems.append("\(name).\(key): relationship has no inverse")
                    }
                    if relationship.isOrdered {
                        problems.append("\(name).\(key): ordered relationships aren't supported")
                    }
                    if relationship.deleteRule == .denyDeleteRule {
                        problems.append("\(name).\(key): Deny delete rule isn't supported")
                    }
                }
            }
        }
        return problems
    }

    /// "Entity.property: kind" for every stored property, sorted. Two apps that sync
    /// through one container must produce the same list.
    public static func fieldManifest(of model: NSManagedObjectModel) -> [String] {
        var lines: [String] = []
        for entity in model.entities {
            let name = entity.name ?? "?"
            for (key, property) in entity.propertiesByName {
                if let attribute = property as? NSAttributeDescription {
                    if attribute.isTransient { continue }
                    lines.append("\(name).\(key): \(kind(of: attribute))")
                } else if let relationship = property as? NSRelationshipDescription {
                    let target = relationship.destinationEntity?.name ?? "?"
                    let arity = relationship.isToMany ? "to-many" : "to-one"
                    lines.append("\(name).\(key): \(arity) \(target)")
                }
            }
        }
        return lines.sorted()
    }

    private static func kind(of attribute: NSAttributeDescription) -> String {
        switch attribute.attributeType {
        case .stringAttributeType: return "string"
        case .booleanAttributeType: return "bool"
        case .integer16AttributeType, .integer32AttributeType, .integer64AttributeType: return "integer"
        case .doubleAttributeType, .floatAttributeType: return "double"
        case .decimalAttributeType: return "decimal"
        case .dateAttributeType: return "date"
        case .binaryDataAttributeType: return "data"
        case .UUIDAttributeType: return "uuid"
        case .URIAttributeType: return "uri"
        case .transformableAttributeType: return "transformable"
        case .compositeAttributeType: return "composite"
        case .objectIDAttributeType: return "objectID"
        default: return "other(\(attribute.attributeType.rawValue))"
        }
    }
}
