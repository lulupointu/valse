import SwiftUI
import AppKit
import MontageCore
import MontageEngine
import Perception

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

    /// Sparkle LICENSE (MIT + the bsdiff / sais-lite / ed25519 notices of the code it bundles), verbatim.
    static let sparkle = """
    Copyright (c) 2006-2013 Andy Matuschak.
    Copyright (c) 2009-2013 Elgato Systems GmbH.
    Copyright (c) 2011-2014 Kornel Lesiński.
    Copyright (c) 2015-2017 Mayur Pawashe.
    Copyright (c) 2014 C.W. Betts.
    Copyright (c) 2014 Petroules Corporation.
    Copyright (c) 2014 Big Nerd Ranch.
    All rights reserved.

    Permission is hereby granted, free of charge, to any person obtaining a copy of
    this software and associated documentation files (the "Software"), to deal in
    the Software without restriction, including without limitation the rights to
    use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
    the Software, and to permit persons to whom the Software is furnished to do so,
    subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
    FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
    COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
    IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
    CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

    =================
    EXTERNAL LICENSES
    =================

    bspatch.c and bsdiff.c, from bsdiff 4.3 <http://www.daemonology.net/bsdiff/>:

    Copyright 2003-2005 Colin Percival
    All rights reserved

    Redistribution and use in source and binary forms, with or without
    modification, are permitted providing that the following conditions 
    are met:
    1. Redistributions of source code must retain the above copyright
       notice, this list of conditions and the following disclaimer.
    2. Redistributions in binary form must reproduce the above copyright
       notice, this list of conditions and the following disclaimer in the
       documentation and/or other materials provided with the distribution.

    THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
    IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
    WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
    ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
    DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
    DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
    OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
    HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
    STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
    IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
    POSSIBILITY OF SUCH DAMAGE.

    --

    sais.c and sais.h, from sais-lite (2010/08/07) <https://sites.google.com/site/yuta256/sais>:

    The sais-lite copyright is as follows:

    Copyright (c) 2008-2010 Yuta Mori All Rights Reserved.

    Permission is hereby granted, free of charge, to any person
    obtaining a copy of this software and associated documentation
    files (the "Software"), to deal in the Software without
    restriction, including without limitation the rights to use,
    copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the
    Software is furnished to do so, subject to the following
    conditions:

    The above copyright notice and this permission notice shall be
    included in all copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
    EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
    OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
    NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
    HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
    WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
    FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
    OTHER DEALINGS IN THE SOFTWARE.

    --

    Portable C implementation of Ed25519, from https://github.com/orlp/ed25519

    Copyright (c) 2015 Orson Peters <orsonpeters@gmail.com>

    This software is provided 'as-is', without any express or implied warranty. In no event will the
    authors be held liable for any damages arising from the use of this software.

    Permission is granted to anyone to use this software for any purpose, including commercial
    applications, and to alter it and redistribute it freely, subject to the following restrictions:

    1. The origin of this software must not be misrepresented; you must not claim that you wrote the
       original software. If you use this software in a product, an acknowledgment in the product
       documentation would be appreciated but is not required.

    2. Altered source versions must be plainly marked as such, and must not be misrepresented as
       being the original software.

    3. This notice may not be removed or altered from any source distribution.

    --

    SUSignatureVerifier.m:

    Copyright (c) 2011 Mark Hamlin.

    All rights reserved.

    Redistribution and use in source and binary forms, with or without
    modification, are permitted providing that the following conditions
    are met:
    1. Redistributions of source code must retain the above copyright
       notice, this list of conditions and the following disclaimer.
    2. Redistributions in binary form must reproduce the above copyright
       notice, this list of conditions and the following disclaimer in the
       documentation and/or other materials provided with the distribution.

    THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
    IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
    WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
    ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
    DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
    DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
    OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
    HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
    STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
    IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
    POSSIBILITY OF SUCH DAMAGE.
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
        ThirdPartyLicense(id: "sparkle", name: "Sparkle", license: "MIT", usageKey: "about.use.sparkle",
                          url: "https://sparkle-project.org", text: sparkle),
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
        WithPerceptionTracking {
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
                        WithPerceptionTracking {
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
                }
                ContentLibraryCredits()
            }
        }
    }
}

/// About ▸ Licenses: every bundled music track / sound effect with author, license and source (AU-001).
struct ContentLibraryCredits: View {
    @State private var expanded = false

    var body: some View {
        WithPerceptionTracking {
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
    }

    @ViewBuilder func group(_ title: String, _ items: [ContentItem]) -> some View {
        Text(verbatim: "\(title) (\(items.count))").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            .padding(.top, 4)
        ForEach(items) { i in
            WithPerceptionTracking {
                // legal credits stay in English: title — author · license · source page
                Text(verbatim: "\(i.kind == .music ? i.title : AudioLibrarySections.title(i)) — \(i.source.author) · \(i.license.id) · \(i.source.name)\(i.source.pack.map { " (\($0))" } ?? "") · \(i.source.page)")
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Settings ▸ About ▸ Updates (SE-015, `UpdateController`) and Environment test (SE-014). With the updater available
/// (release builds): automatic updates switch + check interval, "Check now" and its inline result. Without it (dev builds,
/// UI tests): "Check for updates" opens the releases page in the browser (Info.plist `MontageReleasesURL`) if one is set.
struct UpdatesAndEnvironment: View {
    private let updates = UpdateController.shared
    @State private var report: EnvironmentProbe.Report?
    @State private var running = false
    @State private var packaging = false
    /// Last support package written (SE-018), shown with "Show in Finder".
    @State private var packageURL: URL?

    static var releasesURL: URL? {
        (Bundle.main.infoDictionary?["MontageReleasesURL"] as? String).flatMap { URL(string: $0) }
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 10) {
                if updates.isAvailable { AutoUpdateSettings(updates: updates) }
                HStack(spacing: 10) {
                    Button(tr("about.checkUpdates")) {
                        if updates.isAvailable { updates.checkNow() } else if let u = Self.releasesURL { NSWorkspace.shared.open(u) }
                    }
                    .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
                    .disabled(!updates.isAvailable && Self.releasesURL == nil || updates.state == .checking)
                    .testID("about.checkUpdates")
                    Button(tr(running ? "env.running" : "env.run")) { run() }
                        .buttonStyle(SecondaryButtonStyle()).controlSize(.small).disabled(running).testID("about.environment")
                    Button(tr(packaging ? "support.packaging" : "support.package")) { packageLogs() }
                        .buttonStyle(SecondaryButtonStyle()).controlSize(.small).disabled(packaging).testID("about.packageLogs")
                }
                if updates.isAvailable {
                    UpdateStatusLine(updates: updates)
                } else {
                    Text(loc: Self.releasesURL == nil ? "about.updates.manual" : "about.updates.hint").font(Theme.Fonts.hint).foregroundStyle(Theme.textTertiary)
                }
                if let packageURL {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.zipper").foregroundStyle(Theme.accent)
                        Text(verbatim: tr("support.saved", packageURL.lastPathComponent)).font(Theme.Fonts.hint).foregroundStyle(Theme.textSecondary)
                            .lineLimit(1).truncationMode(.middle).testID("support.saved")
                        Button(tr("support.reveal")) { NSWorkspace.shared.activateFileViewerSelecting([packageURL]) }
                            .buttonStyle(.plain).font(Theme.Fonts.hint).foregroundStyle(Theme.accent)
                    }
                }
                if let report {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: report.smooth ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(report.smooth ? Theme.accent : Color(hex: 0xE8B33A))
                            Text(loc: report.smooth ? "env.verdict.smooth" : "env.verdict.warnings").font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                        }
                        ForEach(report.checks) { c in
                            WithPerceptionTracking {
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
                    }
                    .padding(10)
                    .background(Theme.inset, in: RoundedRectangle(cornerRadius: 6))
                    .testID("env.report")
                }
            }
        }
    }

    /// SE-018: zip logs + environment + settings + crash reports + the open project's project.json into ~/Desktop
    /// (a temp folder in UI tests), never uploaded.
    func packageLogs() {
        packaging = true
        let store = AppShutdown.store
        let json = store.flatMap { try? JSONEncoder().encode($0.rootProject) }
        let name = store?.projectName
        let dir = TestAnchors.isEnabled ? FileManager.default.temporaryDirectory.appendingPathComponent("montage-uitest-support")
            : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        Task {
            let url = await Task.detached(priority: .userInitiated) {
                try? SupportPackage.build(SupportPackage.Contents(projectJSON: json, projectName: name), into: dir)
            }.value
            packaging = false
            packageURL = url
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
