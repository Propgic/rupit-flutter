class AuthUser {
  final String id;
  final String email;
  final String name;
  final String role;
  final String? phone;
  final String? photo;
  final List<String> permissions;
  // Resolved list of chitfund-detail / dashboard UI keys the server hides for this
  // user's role (computed from OrgSettings.uiVisibility). Drives [AuthState.isHidden].
  final List<String> hiddenUI;

  AuthUser({
    required this.id,
    required this.email,
    required this.name,
    required this.role,
    this.phone,
    this.photo,
    this.permissions = const [],
    this.hiddenUI = const [],
  });

  factory AuthUser.fromJson(Map<String, dynamic> j) => AuthUser(
        id: j['id'].toString(),
        email: j['email'] ?? '',
        name: j['name'] ?? '',
        role: j['role'] ?? '',
        phone: j['phone'],
        photo: j['photo'],
        permissions: (j['permissions'] as List?)?.map((e) => e.toString()).toList() ?? const [],
        hiddenUI: (j['hiddenUI'] as List?)?.map((e) => e.toString()).toList() ?? const [],
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'email': email,
        'name': name,
        'role': role,
        'phone': phone,
        'photo': photo,
        'permissions': permissions,
        'hiddenUI': hiddenUI,
      };
}

class AuthOrg {
  final String id;
  final String slug;
  final String name;
  final String? logo;
  final Map<String, bool> features;
  final List<String>? menuOrder;
  // Master switch for editing collections. Off: collections are locked once recorded.
  // On: pending editable; verified governed by verifiedCollectionEditPolicy below.
  final bool allowCollectionEdit;
  // When a VERIFIED collection may still be edited: ALWAYS | WINDOW_24H (up to 24h
  // after verification) | NEVER.
  final String verifiedCollectionEditPolicy;
  // Lets a field officer correct their OWN collection until it's verified. Independent of
  // allowCollectionEdit (which governs admin edits of already-verified collections).
  final bool allowFieldOfficerCollectionEdit;
  // Shows the "Close Loan" action on loan detail (web: Loan Settings → Loan Detail
  // Actions). On by default; when off the API refuses the close too.
  final bool allowLoanClose;
  // Half (0.5-share) chit tickets: two customers splitting one ticket. Gates the
  // share choice when adding a chit member; off by default.
  final bool allowChitHalfTickets;
  // Khata Collection mode: the Collections menu (admins/managers) opens the
  // khata counter — customer → consolidated balance → lump receipt — instead of
  // the collections list. Off by default.
  final bool khataCollectionMode;
  final String? subscriptionStatus;
  final String? renewalDate;
  final String? billingCycle;

  AuthOrg({
    required this.id,
    required this.slug,
    required this.name,
    this.logo,
    required this.features,
    this.menuOrder,
    this.allowCollectionEdit = false,
    this.verifiedCollectionEditPolicy = 'WINDOW_24H',
    this.allowFieldOfficerCollectionEdit = true,
    this.allowLoanClose = true,
    this.allowChitHalfTickets = false,
    this.khataCollectionMode = false,
    this.subscriptionStatus,
    this.renewalDate,
    this.billingCycle,
  });

  factory AuthOrg.fromJson(Map<String, dynamic> j) {
    final feats = <String, bool>{};
    final f = j['features'];
    if (f is Map) {
      f.forEach((k, v) => feats[k.toString()] = v == true);
    }
    List<String>? menu;
    if (j['menuOrder'] is List) {
      menu = (j['menuOrder'] as List).map((e) => e.toString()).toList();
    }
    return AuthOrg(
      id: j['id'].toString(),
      slug: j['slug']?.toString() ?? '',
      name: j['name']?.toString() ?? '',
      logo: j['logo']?.toString(),
      features: feats,
      menuOrder: menu,
      allowCollectionEdit: j['allowCollectionEdit'] == true,
      verifiedCollectionEditPolicy: j['verifiedCollectionEditPolicy']?.toString() ?? 'WINDOW_24H',
      // Absent → enabled (backend default is true); only an explicit false disables it.
      allowFieldOfficerCollectionEdit: j['allowFieldOfficerCollectionEdit'] != false,
      // Absent → enabled (backend default is true); only an explicit false disables it.
      allowLoanClose: j['allowLoanClose'] != false,
      // Both default-false server-side: only an explicit true enables them.
      allowChitHalfTickets: j['allowChitHalfTickets'] == true,
      khataCollectionMode: j['khataCollectionMode'] == true,
      subscriptionStatus: j['subscriptionStatus']?.toString(),
      renewalDate: j['renewalDate']?.toString(),
      billingCycle: j['billingCycle']?.toString(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'slug': slug,
        'name': name,
        'logo': logo,
        'features': features,
        'menuOrder': menuOrder,
        'allowCollectionEdit': allowCollectionEdit,
        'verifiedCollectionEditPolicy': verifiedCollectionEditPolicy,
        'allowFieldOfficerCollectionEdit': allowFieldOfficerCollectionEdit,
        'allowLoanClose': allowLoanClose,
        'allowChitHalfTickets': allowChitHalfTickets,
        'khataCollectionMode': khataCollectionMode,
        'subscriptionStatus': subscriptionStatus,
        'renewalDate': renewalDate,
        'billingCycle': billingCycle,
      };

  // Returns a copy with the given fields overridden. Use this instead of rebuilding
  // AuthOrg by hand so newly added fields are never silently dropped.
  AuthOrg copyWith({
    Map<String, bool>? features,
    List<String>? menuOrder,
    bool? allowCollectionEdit,
    String? verifiedCollectionEditPolicy,
    bool? allowFieldOfficerCollectionEdit,
  }) =>
      AuthOrg(
        id: id,
        slug: slug,
        name: name,
        logo: logo,
        features: features ?? this.features,
        menuOrder: menuOrder ?? this.menuOrder,
        allowCollectionEdit: allowCollectionEdit ?? this.allowCollectionEdit,
        verifiedCollectionEditPolicy: verifiedCollectionEditPolicy ?? this.verifiedCollectionEditPolicy,
        allowFieldOfficerCollectionEdit: allowFieldOfficerCollectionEdit ?? this.allowFieldOfficerCollectionEdit,
        allowLoanClose: allowLoanClose,
        allowChitHalfTickets: allowChitHalfTickets,
        khataCollectionMode: khataCollectionMode,
        subscriptionStatus: subscriptionStatus,
        renewalDate: renewalDate,
        billingCycle: billingCycle,
      );

  bool feature(String key) => features[key] == true;
}

class AuthState {
  final AuthUser? user;
  final AuthOrg? org;
  final String? token;
  final bool loading;
  // Id of the active stored account ("<userId>:<orgId>"); drives the switcher.
  final String? accountId;

  const AuthState({this.user, this.org, this.token, this.loading = true, this.accountId});

  bool get isAuthed => token != null && user != null && org != null;

  AuthState copyWith({AuthUser? user, AuthOrg? org, String? token, bool? loading, String? accountId, bool clear = false}) {
    if (clear) return const AuthState(loading: false);
    return AuthState(
      user: user ?? this.user,
      org: org ?? this.org,
      token: token ?? this.token,
      loading: loading ?? this.loading,
      accountId: accountId ?? this.accountId,
    );
  }

  bool hasPermission(String perm) {
    if (user == null) return false;
    if (user!.role == 'ORG_ADMIN') return true;
    return user!.permissions.contains(perm);
  }

  bool hasRole(String role) => user?.role == role;

  /// Whether a chitfund-detail / dashboard UI element is hidden for this user's
  /// role (per OrgSettings.uiVisibility, resolved server-side into `user.hiddenUI`).
  /// Org admins always see everything. Mirrors web's AuthContext.isHidden(key).
  bool isHidden(String key) {
    if (user == null) return false;
    if (user!.role == 'ORG_ADMIN') return false;
    return user!.hiddenUI.contains(key);
  }
}
