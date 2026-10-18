import AVFoundation
import Foundation

func probe(_ path: String) async -> String {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    do {
        let v = try await asset.loadTracks(withMediaType: .video)
        let a = try await asset.loadTracks(withMediaType: .audio)
        let d = try await asset.load(.duration)
        return "OK video=\(v.count) audio=\(a.count) dur=\(String(format: "%.2f", d.seconds))"
    } catch {
        let e = error as NSError
        return "FAIL \(e.domain) \(e.code) \(e.localizedDescription) | \(e.localizedFailureReason ?? "")"
    }
}

func merge(_ video: String, _ audio: String, _ out: String) async -> String {
    let va = AVURLAsset(url: URL(fileURLWithPath: video)), aa = AVURLAsset(url: URL(fileURLWithPath: audio))
    do {
        guard let sv = try await va.loadTracks(withMediaType: .video).first,
              let sa = try await aa.loadTracks(withMediaType: .audio).first else { return "FAIL no tracks" }
        let comp = AVMutableComposition()
        let vt = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        let at = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
        let vr = try await sv.load(.timeRange), ar = try await sa.load(.timeRange)
        try vt.insertTimeRange(vr, of: sv, at: .zero)
        try at.insertTimeRange(CMTimeRange(start: ar.start, duration: CMTimeMinimum(vr.duration, ar.duration)), of: sa, at: .zero)
        try? FileManager.default.removeItem(atPath: out)
        let ex = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough)!
        ex.outputURL = URL(fileURLWithPath: out); ex.outputFileType = .mp4; ex.shouldOptimizeForNetworkUse = true
        await withCheckedContinuation { c in ex.exportAsynchronously { c.resume() } }
        if ex.status == .completed { return "OK merged -> " + (await probe(out)) }
        let e = ex.error! as NSError
        return "FAIL export \(e.code) \(e.localizedDescription)"
    } catch {
        let e = error as NSError
        return "FAIL \(e.code) \(e.localizedDescription)"
    }
}

let args = CommandLine.arguments.dropFirst()
let sem = DispatchSemaphore(value: 0)
Task {
    if args.first == "merge" {
        let a = Array(args.dropFirst())
        print("merge \((a[0] as NSString).lastPathComponent)+\((a[1] as NSString).lastPathComponent): \(await merge(a[0], a[1], a[2]))")
    } else {
        for p in args { print("\((p as NSString).lastPathComponent): \(await probe(p))") }
    }
    sem.signal()
}
sem.wait()
