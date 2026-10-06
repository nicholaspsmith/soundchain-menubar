// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

/// What TCC says about System Audio Recording ("unknown" when it can't be asked).
public enum CapturePermission: Equatable, Sendable { case authorized, denied, unknown }

/// What to do about System Audio Recording permission.
public enum PermissionAdvice {
    /// Permission was refused, and now TCC says it is granted (the user ticked it in
    /// System Settings): start audio without waiting for Retry.
    public static func shouldStart(denied: Bool, now status: CapturePermission) -> Bool {
        denied && status == .authorized
    }

    /// Offer "Grant System Audio Recording…" when it was refused, or when creating
    /// the tap failed and permission is not known to be granted: missing permission
    /// is then the likeliest cause.
    public static func offersGrant(denied: Bool, tapFailed: Bool, status: CapturePermission) -> Bool {
        denied || (tapFailed && status != .authorized)
    }
}
