import Foundation
import CoreData

extension Sibionics {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<Sibionics> {
        NSFetchRequest<Sibionics>(entityName: "Sibionics")
    }

    @NSManaged public var blePeripheral: BLEPeripheral
}
