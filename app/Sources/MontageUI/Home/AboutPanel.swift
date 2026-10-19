import SwiftUI
import AppKit
import MontageCore
import MontageEngine

/// Third-party components and their licenses (SE-018). Add one entry when a dependency, model or asset pack ships.
/// License texts are legal texts and stay in their original language.
struct ThirdPartyLicense: Identifiable {
    let id: String
    let name: String
    /// SPDX id shown in the list.
    let license: String
    /// Localized key: how Montage uses it.
    let usageKey: String
    let url: String
    let text: String

    static let mitWhisperCpp = """
    MIT License

    Copyright (c) 2023-2024 The ggml authors

    Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated \
    documentation files (the "Software"), to deal in the Software without restriction, including without limitation the \
    rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit \
    persons to whom the Software is furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all copies or substantial portions of the \
    Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE \
    WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR \
    COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR \
    OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
    """

    static let all: [ThirdPartyLicense] = [
        ThirdPartyLicense(id: "ffmpeg", name: "FFmpeg", license: "LGPL-2.1-or-later", usageKey: "about.use.ffmpeg",
                          url: "https://ffmpeg.org/legal.html", text: """
        This software uses code of FFmpeg (https://ffmpeg.org) licensed under the GNU Lesser General Public License \
        version 2.1 or later (LGPLv2.1+). FFmpeg is not linked into Montage: it runs as a separate, unmodified executable \
        (an LGPL build, without --enable-gpl or --enable-nonfree) and is only used to convert formats AVFoundation cannot \
        read into a ProRes + PCM intermediate file.

        FFmpeg is free software; you can redistribute it and/or modify it under the terms of the GNU Lesser General Public \
        License as published by the Free Software Foundation; either version 2.1 of the License, or (at your option) any \
        later version. FFmpeg is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the \
        implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU Lesser General Public License \
        for more details (https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html).

        Written offer: the complete corresponding source code of the FFmpeg build shipped with Montage, with its \
        configuration, is available on request for at least three years from the date of distribution, at no more than \
        the cost of physically performing the distribution. You may replace the bundled ffmpeg executable with your own \
        build ($MONTAGE_FFMPEG).
        """),
        ThirdPartyLicense(id: "whispercpp", name: "whisper.cpp / ggml", license: "MIT", usageKey: "about.use.whispercpp",
                          url: "https://github.com/ggerganov/whisper.cpp", text: mitWhisperCpp),
        ThirdPartyLicense(id: "whisper-models", name: "OpenAI Whisper models (large-v3-turbo)", license: "MIT", usageKey: "about.use.whisperModels",
                          url: "https://github.com/openai/whisper", text: mitWhisperCpp.replacingOccurrences(of: "2023-2024 The ggml authors", with: "2022 OpenAI")),
        ThirdPartyLicense(id: "freeverb", name: "Freeverb (algorithm)", license: "Public domain", usageKey: "about.use.freeverb",
                          url: "https://ccrma.stanford.edu/~jos/pasp/Freeverb.html",
                          text: "Freeverb was written by Jezar at Dreampoint (June 2000) and released into the public domain. Montage contains an independent Swift implementation of the algorithm."),
        ThirdPartyLicense(id: "apple", name: "Apple frameworks (AVFoundation, Metal, Vision, Speech, Core ML)", license: "Apple SDK", usageKey: "about.use.apple",
                          url: "https://developer.apple.com/terms/",
                          text: "System frameworks provided by macOS under the Apple Developer Program License Agreement. They are not redistributed with Montage."),
        ThirdPartyLicense(id: "content", name: "Music & sound effects library (FreePD.com, Free Music Archive, Kenney, OpenGameArt, Wikimedia Commons)",
                          license: "CC0-1.0 / Public domain", usageKey: "about.use.content",
                          url: "https://creativecommons.org/publicdomain/zero/1.0/", text: """
        Every bundled music track and sound effect was released by its author under the Creative Commons CC0 1.0 \
        Universal Public Domain Dedication, or is in the public domain (Wikimedia Commons public-domain templates). \
        You may copy, modify and publish it, including for commercial purposes, without asking permission and without \
        attribution. Montage verified each item's license statement at its source and records the author, source page, \
        retrieval date and checksum (see the list below). Authors credited with thanks: Kevin MacLeod, Rafael Krux, \
        Bryan Teoh, dogsounds (FreePD.com); HoliznaCC0, Loyalty Freak Music (Free Music Archive); \
        Kenney (kenney.nl); rubberduck, artisticdude, AntumDeluge, Nocturnal_Vanguard, Spring Spring, Vinrax \
        (OpenGameArt); Wikimedia Commons \
        contributors.

        CC0 1.0 legal code: https://creativecommons.org/publicdomain/zero/1.0/legalcode
        """),
    ]
}

/// Settings ▸ About: version, the local-only promise, third-party licenses (expandable texts).
struct AboutPanel: View {
    @State private var expanded: String?
    var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "dev"
        return "\(v) (\(b))"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 12).fill(LinearGradient(colors: [Color(hex: 0x6CC9DD), Color(hex: 0x4FB4C9)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 56, height: 56)
                    .overlay(Image(systemName: "film.stack").font(.system(size: 24, weight: .semibold)).foregroundStyle(.black.opacity(0.8)))
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: "Montage").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                    Text(loc: "about.version", version).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    Text(loc: "about.local").font(Theme.Fonts.hint).foregroundStyle(Theme.textTertiary)
                }
            }
            UpdatesAndEnvironment()
            SettingsDivider()
            Text(loc: "about.licenses").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            VStack(spacing: 6) {
                ForEach(ThirdPartyLicense.all) { l in
                    VStack(alignment: .leading, spacing: 6) {
                        Button { expanded = expanded == l.id ? nil : l.id } label: {
                            HStack {
                                Image(systemName: expanded == l.id ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(Theme.textTertiary).frame(width: 12)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: l.name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.textPrimary)
                                    Text(verbatim: tr(l.usageKey)).font(Theme.Fonts.hint).foregroundStyle(Theme.textTertiary)
                                }
                                Spacer()
                                Text(verbatim: l.license).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.accent)
                                    .padding(.horizontal, 6).frame(height: 18)
                                    .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .testID("about.license.\(l.id)")
                        if expanded == l.id {
                            Text(verbatim: l.text).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(Theme.inset, in: RoundedRectangle(cornerRadius: 6))
                            Text(verbatim: l.url).font(Theme.Fonts.hint).foregroundStyle(Theme.textTertiary).textSelection(.enabled)
                        }
                    }
                    .padding(10)
                    .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            ContentLibraryCredits()
        }
    }
}

/// About ▸ Licenses: every bundled music track / sound effect with author, license and source (AU-001).
struct ContentLibraryCredits: View {
    @State private var expanded = false

    var body: some View {
        let items = ContentLibrary.items
        let music = items.filter { $0.kind == .music }, sfx = items.filter { $0.kind == .sfx }
        VStack(alignment: .leading, spacing: 8) {
            SettingsDivider()
            HStack {
                Text(loc: "about.content.title").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                Spacer()
                Text(verbatim: "CC0 / Public domain").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.accent)
                    .padding(.horizontal, 6).frame(height: 18)
                    .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
            }
            Text(verbatim: tr("about.content.summary", music.count, sfx.count)).font(Theme.Fonts.hint).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Button { expanded.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold))
                    Text(loc: expanded ? "about.content.hide" : "about.content.show").font(.system(size: 12))
                }
                .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .testID("about.content.toggle")
            if expanded {
                LazyVStack(alignment: .leading, spacing: 4) {
                    group(tr("audio.lib.music"), music)
                    group(tr("audio.lib.sfx"), sfx)
                }
                .padding(10)
                .background(Theme.inset, in: RoundedRectangle(cornerRadius: 6))
                .testID("about.content.list")
            }
        }
    }

    @ViewBuilder func group(_ title: String, _ items: [ContentItem]) -> some View {
        Text(verbatim: "\(title) (\(items.count))").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            .padding(.top, 4)
        ForEach(items) { i in
            // legal credits stay in English: title — author · license · source page
            Text(verbatim: "\(i.kind == .music ? i.title : AudioLibrarySections.title(i)) — \(i.source.author) · \(i.license.id) · \(i.source.name)\(i.source.pack.map { " (\($0))" } ?? "") · \(i.source.page)")
                .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Settings ▸ About ▸ Check for updates (SE-015) and Environment test (SE-014). Montage never contacts a server on its
/// own: "Check for updates" only opens the releases page in the browser when clicked (Info.plist `MontageReleasesURL`).
struct UpdatesAndEnvironment: View {
    @State private var report: EnvironmentProbe.Report?
    @State private var running = false

    static var releasesURL: URL? {
        (Bundle.main.infoDictionary?["MontageReleasesURL"] as? String).flatMap { URL(string: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button(tr("about.checkUpdates")) { if let u = Self.releasesURL { NSWorkspace.shared.open(u) } }
                    .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
                    .disabled(Self.releasesURL == nil).testID("about.checkUpdates")
                Button(tr(running ? "env.running" : "env.run")) { run() }
                    .buttonStyle(SecondaryButtonStyle()).controlSize(.small).disabled(running).testID("about.environment")
            }
            Text(loc: Self.releasesURL == nil ? "about.updates.manual" : "about.updates.hint").font(Theme.Fonts.hint).foregroundStyle(Theme.textTertiary)
            if let report {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: report.smooth ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(report.smooth ? Theme.accent : Color(hex: 0xE8B33A))
                        Text(loc: report.smooth ? "env.verdict.smooth" : "env.verdict.warnings").font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                    }
                    ForEach(report.checks) { c in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Image(systemName: c.status == .ok ? "checkmark.circle" : c.status == .warning ? "exclamationmark.circle" : "xmark.circle")
                                    .font(.system(size: 11)).foregroundStyle(c.status == .ok ? Theme.accent : Color(hex: 0xE8B33A))
                                Text(verbatim: tr(c.titleKey)).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).frame(width: 150, alignment: .leading)
                                Text(verbatim: c.value).font(.system(size: 12)).foregroundStyle(Theme.textPrimary).lineLimit(1).truncationMode(.middle)
                                    .testID("env.value.\(c.id)")
                            }
                            if let a = c.adviceKey {
                                Text(loc: a).font(Theme.Fonts.hint).foregroundStyle(Theme.textTertiary).padding(.leading, 23)
                            }
                        }
                    }
                }
                .padding(10)
                .background(Theme.inset, in: RoundedRectangle(cornerRadius: 6))
                .testID("env.report")
            }
        }
    }

    func run() {
        running = true
        Task {
            let r = await Task.detached(priority: .userInitiated) { EnvironmentProbe.run() }.value
            report = r
            running = false
        }
    }
}
