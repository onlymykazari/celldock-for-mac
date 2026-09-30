import CModemBridge
import Foundation

struct DiscoveredModemDevice: Equatable, Identifiable {
    let vendorID: UInt16
    let productID: UInt16
    let locationID: UInt32
    let registryID: UInt64
    let usbVendorName: String?
    let usbProductName: String?

    var hardwareFamily: ModemHardwareFamily {
        .classify(vendorName: usbVendorName, productName: usbProductName)
    }

    var id: UInt32 { locationID }

    var moduleID: CellularModuleID {
        CellularModuleID(rawValue: String(format: "usb-location:%08X", locationID))
    }

    var usbIdentity: String {
        String(format: "%04X:%04X", vendorID, productID)
    }

    var locationDescription: String {
        String(format: "0x%08X", locationID)
    }
}

struct ModemUSBNames: Equatable {
    let vendor: String?
    let product: String?
}

enum ModemUSBIdentityResolver {
    static func names(for locationID: UInt32) -> ModemUSBNames {
        var vendor = [CChar](repeating: 0, count: 128)
        var product = [CChar](repeating: 0, count: 128)
        let found = vendor.withUnsafeMutableBufferPointer { vendorBuffer in
            product.withUnsafeMutableBufferPointer { productBuffer in
                celldock_modem_copy_usb_names(
                    locationID,
                    vendorBuffer.baseAddress,
                    vendorBuffer.count,
                    productBuffer.baseAddress,
                    productBuffer.count
                )
            }
        }
        guard found == 1 else { return ModemUSBNames(vendor: nil, product: nil) }
        return ModemUSBNames(
            vendor: normalizedString(from: vendor),
            product: normalizedString(from: product)
        )
    }

    private static func normalizedString(from buffer: [CChar]) -> String? {
        let value = String(cString: buffer)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

final class ModemInventoryService {
    var onDevices: (([DiscoveredModemDevice]) -> Void)?

    private let queue = DispatchQueue(
        label: "app.celldockplus.mac.modem-inventory",
        qos: .utility
    )
    private var timer: DispatchSourceTimer?
    private var lastPublishedDevices: [DiscoveredModemDevice]?

    func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            self.scanAndPublish()

            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(
                deadline: .now() + .seconds(2),
                repeating: .seconds(2),
                leeway: .milliseconds(250)
            )
            timer.setEventHandler { [weak self] in self?.scanAndPublish() }
            self.timer = timer
            timer.resume()
        }
    }

    func refresh() {
        queue.async { [weak self] in self?.scanAndPublish(force: true) }
    }

    func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    private func scanAndPublish(force: Bool = false) {
        let devices = Self.scan()
        guard force || devices != lastPublishedDevices else { return }
        lastPublishedDevices = devices
        DispatchQueue.main.async { [weak self] in
            self?.onDevices?(devices)
        }
    }

    private static func scan() -> [DiscoveredModemDevice] {
        var capacity = Int(celldock_modem_copy_devices(nil, 0))
        guard capacity > 0 else { return [] }

        for _ in 0 ..< 2 {
            var rawDevices = Array(
                repeating: CellDockModemDevice(
                    vendor_id: 0,
                    product_id: 0,
                    location_id: 0,
                    registry_id: 0
                ),
                count: capacity
            )
            let discoveredCount = rawDevices.withUnsafeMutableBufferPointer { buffer in
                celldock_modem_copy_devices(buffer.baseAddress, buffer.count)
            }
            if discoveredCount > capacity {
                capacity = discoveredCount
                continue
            }
            return rawDevices.prefix(discoveredCount).map { device in
                let names = ModemUSBIdentityResolver.names(for: device.location_id)
                return DiscoveredModemDevice(
                    vendorID: device.vendor_id,
                    productID: device.product_id,
                    locationID: device.location_id,
                    registryID: device.registry_id,
                    usbVendorName: names.vendor,
                    usbProductName: names.product
                )
            }
        }
        return []
    }
}
