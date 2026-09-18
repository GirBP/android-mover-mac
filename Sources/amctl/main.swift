import Foundation
import AndroidMoverCore

/// amctl — headless-драйвер над Core без UI. Поки три команди:
///   amctl contract dump                      — JSON-контракт словника скриптів у stdout
///   amctl devices [--adb <шлях>]              — пристрої, які бачить adb
///   amctl capture --out <файл> [--adb <шлях>] [--serial <s>] [--root /sdcard/DCIM]
///        — записує транскрипт реальних викликів (devices, identity, listDir, statFS, findFiles,
///          mdns check) через RecordingTransport → Tests/Golden. Інтенти застосунку — після M6.
enum AMCTL {
    static func run(_ args: [String]) async -> Int32 {
        guard let command = args.first else { return usage() }
        switch command {
        case "contract":
            guard args.count >= 2, args[1] == "dump" else { return usage() }
            do {
                FileHandle.standardOutput.write(try ADBContract.manifestJSON())
                return 0
            } catch {
                return fail("contract: \(error)")
            }
        case "devices":
            guard let adb = adbPath(from: args) else { return fail("adb не знайдено: вкажіть --adb <шлях> або $ADB_PATH") }
            do {
                let devices = try await ADBClient(adbPath: adb).devices()
                for device in devices {
                    print("\(device.serial)\t\(device.state)\t\(device.model ?? "-")\t\(device.isWireless ? "wifi" : "usb")")
                }
                return 0
            } catch {
                return fail("devices: \(error.localizedDescription)")
            }
        case "capture":
            return await capture(args)
        default:
            return usage()
        }
    }

    static func capture(_ args: [String]) async -> Int32 {
        guard let out = option("--out", in: args) else { return fail("capture: потрібен --out <файл.jsonl>") }
        guard let adb = adbPath(from: args) else { return fail("adb не знайдено: вкажіть --adb <шлях> або $ADB_PATH") }
        let root = option("--root", in: args) ?? "/sdcard/DCIM"
        let outURL = URL(fileURLWithPath: out)
        try? FileManager.default.removeItem(at: outURL)
        let transport = RecordingTransport(base: SpawnTransport(executable: adb), fileURL: outURL)
        let client = ADBClient(transport: transport, adbPath: adb)
        do {
            let devices = try await client.devices()
            let serial: String
            if let explicit = option("--serial", in: args) {
                serial = explicit
            } else if let ready = devices.first(where: { $0.state == .ready }) {
                serial = ready.serial
            } else {
                return fail("capture: немає готового пристрою (\(devices.count) у списку)")
            }
            print("пристрій: \(serial)")
            let identity = try await client.deviceIdentity(on: serial)
            print("ідентичність: \(identity.stableID) (\(identity.source.rawValue)), модель: \(identity.model ?? "-")")
            let listing = try await client.listDirectory(root, on: serial)
            print("\(root): \(listing.count) елементів")
            if let info = try? await client.storageInfo(for: root, on: serial) {
                print("вільно: \(info.availableBytes) з \(info.totalBytes) байтів")
            }
            let files = try await client.recursiveFiles(root, on: serial)
            print("файлів рекурсивно: \(files.count)")
            let mdns = await client.mdnsCheck()
            print("mDNS: \(mdns ? "є" : "нема")")
            print("транскрипт: \(outURL.path)")
            return 0
        } catch {
            return fail("capture: \(error.localizedDescription)")
        }
    }

    static func adbPath(from args: [String]) -> String? {
        option("--adb", in: args) ?? ADBClient.discover()
    }

    static func option(_ name: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    static func usage() -> Int32 {
        FileHandle.standardError.write(Data("""
        amctl — headless-драйвер Android Mover (v0)
          amctl contract dump
          amctl devices [--adb <шлях>]
          amctl capture --out <файл.jsonl> [--adb <шлях>] [--serial <serial>] [--root <тека>]

        """.utf8))
        return 2
    }

    static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        return 1
    }
}

let code = await AMCTL.run(Array(CommandLine.arguments.dropFirst()))
exit(code)
