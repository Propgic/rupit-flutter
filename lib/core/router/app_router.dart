import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../auth/auth_controller.dart';
import '../widgets/common.dart';
import '../../features/auth/login_page.dart';
import '../../features/dashboard/dashboard_page.dart';
import '../../features/profile/profile_page.dart';
import '../../features/notifications/notifications_page.dart';
import '../../features/app_shell.dart';
import '../../features/customers/ui/customer_list_page.dart';
import '../../features/customers/ui/customer_form_page.dart';
import '../../features/customers/ui/customer_detail_page.dart';
import '../../features/customers/ui/deleted_customers_page.dart';
import '../../features/loans/ui/loan_list_page.dart';
import '../../features/loans/ui/assign_loan_page.dart';
import '../../features/loans/ui/loan_create_page.dart';
import '../../features/loans/ui/loan_detail_page.dart';
import '../../features/loans/ui/overdue_list_page.dart';
import '../../features/loan_groups/ui/loan_group_list_page.dart';
import '../../features/loan_groups/ui/loan_group_form_page.dart';
import '../../features/loan_groups/ui/loan_group_detail_page.dart';
import '../../features/collections/ui/collection_list_page.dart';
import '../../features/collections/ui/collection_form_page.dart';
import '../../features/collections/ui/daily_summary_page.dart';
import '../../features/collections/ui/verify_collections_page.dart';
import '../../features/collections/ui/group_collection_page.dart';
import '../../features/collections/ui/receipt_page.dart';
import '../../features/savings/ui/savings_list_page.dart';
import '../../features/savings/ui/savings_form_page.dart';
import '../../features/savings/ui/savings_detail_page.dart';
import '../../features/chitfunds/ui/chitfund_list_page.dart';
import '../../features/chitfunds/ui/chitfund_form_page.dart';
import '../../features/chitfunds/ui/chitfund_detail_page.dart';
import '../../features/expenses/ui/expense_list_page.dart';
import '../../features/expenses/ui/expense_form_page.dart';
import '../../features/expenses/ui/expense_report_page.dart';
import '../../features/investors/ui/investor_list_page.dart';
import '../../features/investors/ui/investor_form_page.dart';
import '../../features/investors/ui/investor_detail_page.dart';
import '../../features/investors/ui/investment_form_page.dart';
import '../../features/investors/ui/investment_detail_page.dart';
import '../../features/team/ui/team_list_page.dart';
import '../../features/team/ui/team_form_page.dart';
import '../../features/team/ui/team_detail_page.dart';
import '../../features/reports/ui/reports_index_page.dart';
import '../../features/reports/ui/loan_report_page.dart';
import '../../features/reports/ui/collection_report_page.dart';
import '../../features/reports/ui/overdue_report_page.dart';
import '../../features/reports/ui/savings_report_page.dart';
import '../../features/reports/ui/daily_cash_report_page.dart';
import '../../features/reports/ui/portfolio_report_page.dart';
import '../../features/reports/ui/investment_report_page.dart';
import '../../features/reports/ui/customer_report_page.dart';
import '../../features/reports/ui/progress_report_page.dart';
import '../../features/reports/ui/group_collection_report_page.dart';
import '../../features/reports/ui/chitfund_returns_report_page.dart';
import '../../features/settings/ui/settings_page.dart';
import '../../features/settings/ui/roles_permissions_page.dart';
import '../../features/collections/ui/collection_map_page.dart';
import '../../features/customers/ui/consolidated_balance_page.dart';
import '../../features/chitfunds/ui/chitfund_auction_detail_page.dart';
import '../../features/expenses/ui/team_salaries_page.dart';
import '../../features/search/ui/search_page.dart';

class _AuthListenable extends ChangeNotifier {
  _AuthListenable(this.ref) {
    ref.listen(authProvider, (_, __) => notifyListeners());
  }
  final Ref ref;
}

final routerProvider = Provider<GoRouter>((ref) {
  final listenable = _AuthListenable(ref);
  return GoRouter(
    refreshListenable: listenable,
    initialLocation: '/',
    redirect: (context, state) {
      final auth = ref.read(authProvider);
      if (auth.loading) return null;
      final loggingIn = state.matchedLocation == '/login';
      // Adding an account is reachable while already signed in (it appends a
      // second identity), so it's exempt from the authed→home redirect.
      final addingAccount = state.matchedLocation == '/add-account';
      if (!auth.isAuthed && !loggingIn && !addingAccount) return '/login';
      if (auth.isAuthed && loggingIn) return '/';
      return null;
    },
    routes: [
      GoRoute(path: '/login', builder: (_, __) => const LoginPage()),
      GoRoute(path: '/add-account', builder: (_, __) => const LoginPage(addMode: true)),
      ShellRoute(
        builder: (ctx, st, child) => AppShell(child: child),
        routes: [
          GoRoute(path: '/', redirect: (_, __) => '/dashboard'),
          GoRoute(path: '/dashboard', builder: (_, __) => const DashboardPage()),
          GoRoute(path: '/profile', builder: (_, __) => const ProfilePage()),
          GoRoute(path: '/notifications', builder: (_, __) => const NotificationsPage()),

          GoRoute(path: '/customers', builder: (_, state) => CustomerListPage(initialStatus: state.uri.queryParameters['status'])),
          GoRoute(path: '/customers/new', builder: (_, __) => const CustomerFormPage()),
          GoRoute(path: '/customers/deleted', builder: (_, __) => const DeletedCustomersPage()),
          GoRoute(path: '/customers/:id', builder: (_, s) => CustomerDetailPage(id: s.pathParameters['id']!)),
          GoRoute(path: '/customers/:id/edit', builder: (_, s) => CustomerFormPage(id: s.pathParameters['id'])),

          GoRoute(path: '/loans', builder: (_, state) => LoanListPage(fromDate: state.uri.queryParameters['fromDate'], toDate: state.uri.queryParameters['toDate'])),
          GoRoute(path: '/assign-loans', builder: (_, __) => const AssignLoanPage()),
          GoRoute(path: '/loans/new', builder: (_, __) => const LoanCreatePage()),
          GoRoute(path: '/loans/overdue', builder: (_, __) => const OverdueListPage()),
          GoRoute(path: '/loans/:id', builder: (_, s) => LoanDetailPage(id: s.pathParameters['id']!)),

          GoRoute(path: '/loan-groups', builder: (_, __) => const LoanGroupListPage()),
          GoRoute(path: '/loan-groups/new', builder: (_, __) => const LoanGroupFormPage()),
          GoRoute(path: '/loan-groups/:id', builder: (_, s) => LoanGroupDetailPage(id: s.pathParameters['id']!)),
          GoRoute(path: '/loan-groups/:id/edit', builder: (_, s) => LoanGroupFormPage(id: s.pathParameters['id'])),

          GoRoute(path: '/collections', builder: (_, __) => const CollectionListPage()),
          GoRoute(path: '/collections/new', builder: (_, s) => CollectionFormPage(loanId: s.uri.queryParameters['loanId'])),
          GoRoute(path: '/collections/summary', builder: (_, __) => const DailySummaryPage()),
          GoRoute(path: '/collections/verify', builder: (_, s) => VerifyCollectionsPage(collectedById: s.uri.queryParameters['collectedById'], collectorName: s.uri.queryParameters['name'])),
          GoRoute(path: '/collections/group', builder: (_, __) => const GroupCollectionPage()),
          GoRoute(path: '/collections/map', builder: (_, __) => const CollectionMapPage()),
          GoRoute(path: '/collections/:id/receipt', builder: (_, s) => ReceiptPage(id: s.pathParameters['id']!)),

          GoRoute(path: '/savings', builder: (_, __) => const SavingsListPage()),
          GoRoute(path: '/savings/new', builder: (_, __) => const SavingsFormPage()),
          GoRoute(path: '/savings/:id', builder: (_, s) => SavingsDetailPage(id: s.pathParameters['id']!)),

          GoRoute(path: '/chitfunds', builder: (_, __) => const ChitfundListPage()),
          GoRoute(path: '/chitfunds/new', builder: (_, __) => const ChitfundFormPage()),
          GoRoute(path: '/chitfunds/:id', builder: (_, s) => ChitfundDetailPage(
                id: s.pathParameters['id']!,
                initialTab: s.uri.queryParameters['tab'],
                initialMemberId: s.uri.queryParameters['member'],
              )),
          GoRoute(path: '/chitfunds/:id/auctions/:auctionId', builder: (_, s) => ChitfundAuctionDetailPage(chitfundId: s.pathParameters['id']!, auctionId: s.pathParameters['auctionId']!)),

          GoRoute(path: '/expenses', builder: (_, __) => const ExpenseListPage()),
          GoRoute(path: '/expenses/new', builder: (_, __) => const ExpenseFormPage()),
          GoRoute(path: '/expenses/team-salaries', builder: (_, __) => const TeamSalariesPage()),
          GoRoute(path: '/expenses/:id/edit', builder: (_, state) => ExpenseFormPage(expenseId: state.pathParameters['id'])),
          GoRoute(path: '/reports/expenses', builder: (_, __) => const ExpenseReportPage()),

          GoRoute(path: '/investors', builder: (_, __) => const InvestorListPage()),
          GoRoute(path: '/investors/new', builder: (_, __) => const InvestorFormPage()),
          GoRoute(path: '/investors/:id', builder: (_, s) => InvestorDetailPage(id: s.pathParameters['id']!)),
          GoRoute(path: '/investors/:id/edit', builder: (_, s) => InvestorFormPage(id: s.pathParameters['id'])),
          GoRoute(path: '/investments/new', builder: (_, __) => const InvestmentFormPage()),
          GoRoute(path: '/investments/:id', builder: (_, s) => InvestmentDetailPage(id: s.pathParameters['id']!)),

          GoRoute(path: '/team', builder: (_, __) => const TeamListPage()),
          GoRoute(path: '/team/new', builder: (_, __) => const TeamFormPage()),
          GoRoute(path: '/team/:id', builder: (_, s) => TeamDetailPage(id: s.pathParameters['id']!)),
          GoRoute(path: '/team/:id/edit', builder: (_, s) => TeamFormPage(id: s.pathParameters['id'])),

          GoRoute(path: '/reports', builder: (_, __) => const ReportsIndexPage()),
          GoRoute(path: '/reports/loans', builder: (_, __) => const LoanReportPage()),
          GoRoute(path: '/reports/collections', builder: (_, __) => const CollectionReportPage()),
          GoRoute(path: '/reports/overdue', builder: (_, __) => const OverdueReportPage()),
          GoRoute(path: '/reports/savings', builder: (_, __) => const SavingsReportPage()),
          GoRoute(path: '/reports/daily-cash', builder: (_, __) => const DailyCashReportPage()),
          GoRoute(path: '/reports/portfolio', builder: (_, __) => const PortfolioReportPage()),
          GoRoute(path: '/reports/investments', builder: (_, __) => const InvestmentReportPage()),
          GoRoute(path: '/reports/customer', builder: (_, __) => const CustomerReportPage()),
          GoRoute(path: '/reports/customer/:id', builder: (_, s) => CustomerReportPage(customerId: s.pathParameters['id'])),
          GoRoute(path: '/reports/progress', builder: (_, __) => const ProgressReportPage()),
          GoRoute(path: '/reports/group-collection', builder: (_, __) => const GroupCollectionReportPage()),
          GoRoute(path: '/reports/chit-returns', builder: (_, __) => const ChitfundReturnsReportPage()),

          GoRoute(path: '/settings', builder: (_, __) => const SettingsPage()),
          GoRoute(path: '/settings/roles', builder: (_, __) => const RolesPermissionsPage()),

          GoRoute(path: '/search', builder: (_, __) => const SearchPage()),
          GoRoute(path: '/consolidated-balance', builder: (_, __) => const ConsolidatedBalanceSheetPage()),
        ],
      ),
    ],
    errorBuilder: (_, s) => Scaffold(
      body: ErrorView(message: 'Not found: ${s.matchedLocation}', onRetry: () => s.uri),
    ),
  );
});
