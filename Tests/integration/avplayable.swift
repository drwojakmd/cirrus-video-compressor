// Exit 0 if Apple's own playback stack (AVFoundation: what Quick Look and QuickTime
// use) can decode a frame of the file, 1 otherwise.   swift avplayable.swift FILE
import AVFoundation
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
let sema = DispatchSemaphore(value: 0)
var ok = false
gen.generateCGImageAsynchronously(for: CMTime(seconds: 1, preferredTimescale: 600)) { img, _, err in ok = img != nil && err == nil; sema.signal() }
sema.wait()
print(ok ? "playable" : "not playable")
exit(ok ? 0 : 1)
