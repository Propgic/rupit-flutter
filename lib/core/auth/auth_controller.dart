import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../api/api_client.dart';
import 'account_store.dart';
import 'auth_models.dart';
import 'biometric_service.dart';

class AuthController extends Notifier<AuthState> {
  @override
  AuthState build() {
    _bootstrap();
    return const AuthState(loading: true);
  }

  Future<void> _bootstrap() async {
    // Upgrade a legacy single-session install into the multi-account store.
    await AccountStore.migrateFromLegacy();
    final restored = await _activateUsable(preferred: await AccountStore.activeId());
    if (restored) {
      _refreshMe(); // background re-sync
    } else {
      state = const AuthState(loading: false);
    }
  }

  /// Loads [state] from the preferred account if it still has tokens, else from
  /// the first account that does. Returns false when no usable account remains.
  Future<bool> _activateUsable({String? preferred}) async {
    final accounts = await AccountStore.list();
    StoredAccount? chosen;
    if (preferred != null) {
      for (final a in accounts) {
        if (a.id == preferred && (await AccountStore.tokensFor(a.id)).access != null) {
          chosen = a;
          break;
        }
      }
    }
    if (chosen == null) {
      for (final a in accounts) {
        if ((await AccountStore.tokensFor(a.id)).access != null) {
          chosen = a;
          break;
        }
      }
    }
    if (chosen == null) return false;
    await AccountStore.setActive(chosen.id);
    final t = await AccountStore.tokensFor(chosen.id);
    state = AuthState(
      accountId: chosen.id,
      token: t.access,
      user: AuthUser.fromJson(chosen.user),
      org: AuthOrg.fromJson(chosen.org),
      loading: false,
    );
    return true;
  }

  Future<void> refreshMe() => _refreshMe();

  Future<void> _refreshMe() async {
    // Pin the account this runs for: a rapid switch mid-flight must not let a
    // stale /auth/me response overwrite a different (now-active) account.
    final forAccount = state.accountId;
    try {
      final api = ref.read(apiClientProvider);
      final data = await api.get('/auth/me') as Map<String, dynamic>;
      if (state.accountId != forAccount) return;
      final user = AuthUser.fromJson(Map<String, dynamic>.from(data['user']));
      final org = AuthOrg.fromJson(Map<String, dynamic>.from(data['org']));
      await AccountStore.updateActiveProfile(user: user.toJson(), org: org.toJson());
      state = state.copyWith(user: user, org: org);
    } catch (_) {}
  }

  Future<List<Map<String, dynamic>>> loginStep1(String phone, String password) async {
    final api = ref.read(apiClientProvider);
    final data = await api.post('/auth/login', data: {'phone': phone, 'password': password});
    // Multi-org: backend returns the org list to choose from instead of a session.
    if (data is Map && data['requireOrgSelection'] == true) {
      return (data['orgs'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    }
    await _persistLogin(Map<String, dynamic>.from(data as Map), phone: phone);
    return [];
  }

  Future<void> loginStep2({required String phone, required String password, required String orgId}) async {
    final api = ref.read(apiClientProvider);
    final data = await api.post('/auth/login', data: {'phone': phone, 'password': password, 'orgId': orgId});
    await _persistLogin(Map<String, dynamic>.from(data as Map), phone: phone);
  }

  /// All stored accounts, for the in-app switcher.
  Future<List<StoredAccount>> listAccounts() => AccountStore.list();

  /// Orgs the active login belongs to. Drives the "switch organization" section
  /// of the account switcher (each entry: `{ id, name, slug, logo, role, current }`).
  Future<List<Map<String, dynamic>>> myOrgs() async {
    final api = ref.read(apiClientProvider);
    final data = await api.get('/auth/my-orgs');
    final list = (data is Map ? data['orgs'] : null) as List?;
    return (list ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  /// Server-side switch to another org of the *active login*. Mints a fresh
  /// session, which we persist as its own switchable account and activate.
  Future<void> switchOrg(String orgId) async {
    final api = ref.read(apiClientProvider);
    final data = await api.post('/auth/switch-org', data: {'orgId': orgId});
    await _persistLogin(Map<String, dynamic>.from(data as Map), phone: state.user?.phone);
  }

  /// Local switch to an already-stored account — no network, no re-auth.
  Future<void> switchToAccount(String accountId) async {
    final accounts = await AccountStore.list();
    StoredAccount? acct;
    for (final a in accounts) {
      if (a.id == accountId) {
        acct = a;
        break;
      }
    }
    if (acct == null) return;
    final t = await AccountStore.tokensFor(accountId);
    if (t.access == null) {
      // Tokens were cleared by a hard 401 — needs a fresh sign-in.
      throw ApiException('Please sign in to this account again');
    }
    await AccountStore.setActive(accountId);
    state = AuthState(
      accountId: accountId,
      token: t.access,
      user: AuthUser.fromJson(acct.user),
      org: AuthOrg.fromJson(acct.org),
      loading: false,
    );
    _refreshMe(); // background re-sync of profile/permissions
  }

  Future<void> _persistLogin(Map<String, dynamic> data, {String? phone}) async {
    final token = data['token'] as String;
    final user = AuthUser.fromJson(Map<String, dynamic>.from(data['user']));
    final org = AuthOrg.fromJson(Map<String, dynamic>.from(data['org']));
    final id = AccountStore.accountId(user.id, org.id);
    await AccountStore.upsert(
      account: StoredAccount(
        id: id,
        phone: phone ?? user.phone ?? '',
        user: user.toJson(),
        org: org.toJson(),
      ),
      access: token,
      refresh: data['refreshToken'] as String?,
      makeActive: true,
    );
    state = AuthState(accountId: id, token: token, user: user, org: org, loading: false);
  }

  /// Sign out of the *active* account (best-effort server revoke of its refresh
  /// token), then fall back to another stored account if one exists; otherwise
  /// tear everything down and return to the login screen.
  Future<void> logout() async {
    final id = state.accountId ?? await AccountStore.activeId();
    try {
      final rt = id != null ? (await AccountStore.tokensFor(id)).refresh : null;
      await ref.read(apiClientProvider).post('/auth/logout', data: {'refreshToken': rt});
    } catch (_) {}
    if (id != null) await AccountStore.remove(id);
    final switched = await _activateUsable();
    if (switched) {
      _refreshMe();
    } else {
      // No accounts left — disable biometric so the next login is a full sign-in.
      await ref.read(biometricServiceProvider).disable();
      state = const AuthState(loading: false);
    }
  }

  /// Remove a *non-active* account from this device (local only — its refresh
  /// token expires server-side). Removing the active account defers to [logout].
  Future<void> logoutAccount(String accountId) async {
    final activeId = state.accountId ?? await AccountStore.activeId();
    if (accountId == activeId) {
      await logout();
      return;
    }
    await AccountStore.remove(accountId);
    // Active account (state) is unchanged; the caller refreshes the list.
  }

  Future<void> updateOrgFeatures(Map<String, bool> features) async {
    if (state.org == null) return;
    final updated = state.org!.copyWith(features: {...state.org!.features, ...features});
    await AccountStore.updateActiveProfile(org: updated.toJson());
    state = state.copyWith(org: updated);
  }

  // Sync org-level Loan Settings into the cached session after a settings save, so
  // collection edit gating (receipt page) reflects the change without a re-login.
  Future<void> updateOrgSettings({bool? allowCollectionEdit, String? verifiedCollectionEditPolicy, bool? allowFieldOfficerCollectionEdit}) async {
    if (state.org == null) return;
    final updated = state.org!.copyWith(
      allowCollectionEdit: allowCollectionEdit,
      verifiedCollectionEditPolicy: verifiedCollectionEditPolicy,
      allowFieldOfficerCollectionEdit: allowFieldOfficerCollectionEdit,
    );
    await AccountStore.updateActiveProfile(org: updated.toJson());
    state = state.copyWith(org: updated);
  }

  Future<void> updateProfilePhoto(String? photo, {String? name, String? phone}) async {
    if (state.user == null) return;
    final updated = AuthUser(
      id: state.user!.id,
      email: state.user!.email,
      name: name ?? state.user!.name,
      role: state.user!.role,
      phone: phone ?? state.user!.phone,
      photo: photo ?? state.user!.photo,
      permissions: state.user!.permissions,
      hiddenUI: state.user!.hiddenUI,
    );
    await AccountStore.updateActiveProfile(user: updated.toJson());
    state = state.copyWith(user: updated);
  }
}

final authProvider = NotifierProvider<AuthController, AuthState>(AuthController.new);
