import 'package:flutter/material.dart';
import '../../widgets/ui/ui.dart';
import '../../l10n/app_localizations.dart';
import '../../styles/tokens.dart';

class IconPickerPage extends StatefulWidget {
  final String? currentIcon;
  final String kind; // expense 或 income

  const IconPickerPage({
    super.key,
    this.currentIcon,
    required this.kind,
  });

  @override
  State<IconPickerPage> createState() => _IconPickerPageState();
}

class _IconPickerPageState extends State<IconPickerPage> with TickerProviderStateMixin {
  late TabController _tabController;
  String? _selectedIcon;

  @override
  void initState() {
    super.initState();
    _selectedIcon = widget.currentIcon;
    // tab 数与 kind 固定对应（支出 8 类 / 收入 4 类）。initState 里不能调
    // _getIconCategories()：它要读 AppLocalizations（inherited widget，
    // initState 期访问会断言崩溃），且此处本就只需要长度。
    _tabController =
        TabController(length: widget.kind == 'expense' ? 8 : 4, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final categories = _getIconCategories();

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: PiggyTitleBar(
        title: AppLocalizations.of(context).iconPickerTitle,
        showBack: true,
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop(_selectedIcon);
            },
            child: Text(AppLocalizations.of(context).commonConfirm),
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          labelColor: PiggyTokens.textPrimary(context),
          unselectedLabelColor: PiggyTokens.textSecondary(context),
          tabs: categories.map((category) => Tab(text: category.name)).toList(),
        ),
        bottomHeight: 48,
      ),
      body: Padding(
        padding: EdgeInsets.only(
          top: PiggyTokens.topScrollablePadding(context, extra: 48),
        ),
        child: TabBarView(
          controller: _tabController,
          children: categories.map((category) {
            return _IconGrid(
              icons: category.icons,
              selectedIcon: _selectedIcon,
              onIconSelected: (icon) {
                setState(() {
                  _selectedIcon = icon;
                });
              },
            );
          }).toList(),
        ),
      ),
    );
  }

  List<_IconCategory> _getIconCategories() {
    final l10n = AppLocalizations.of(context);
    if (widget.kind == 'expense') {
      return [
        _IconCategory(
          name: l10n.iconCategoryDining,
          icons: [
            _IconItem('restaurant', Icons.restaurant, l10n.iconLabelRestaurant),
            _IconItem('local_dining', Icons.local_dining, l10n.iconLabelLocalDining),
            _IconItem('fastfood', Icons.fastfood, l10n.iconLabelFastfood),
            _IconItem('local_cafe', Icons.local_cafe, l10n.iconLabelLocalCafe),
            _IconItem('local_bar', Icons.local_bar, l10n.iconLabelLocalBar),
            _IconItem('cake', Icons.cake, l10n.iconLabelCake),
            _IconItem('local_pizza', Icons.local_pizza, l10n.iconLabelLocalPizza),
            _IconItem('icecream', Icons.icecream, l10n.iconLabelIcecream),
          ],
        ),
        _IconCategory(
          name: l10n.iconCategoryTransport,
          icons: [
            _IconItem('directions_car', Icons.directions_car, l10n.iconLabelDirectionsCar),
            _IconItem('directions_bus', Icons.directions_bus, l10n.iconLabelDirectionsBus),
            _IconItem('directions_subway', Icons.directions_subway, l10n.iconLabelDirectionsSubway),
            _IconItem('local_taxi', Icons.local_taxi, l10n.iconLabelLocalTaxi),
            _IconItem('flight', Icons.flight, l10n.iconLabelFlight),
            _IconItem('train', Icons.train, l10n.iconLabelTrain),
            _IconItem('directions_bike', Icons.directions_bike, l10n.iconLabelDirectionsBike),
            _IconItem('directions_walk', Icons.directions_walk, l10n.iconLabelDirectionsWalk),
            _IconItem('local_gas_station', Icons.local_gas_station, l10n.iconLabelLocalGasStation),
            _IconItem('local_parking', Icons.local_parking, l10n.iconLabelLocalParking),
          ],
        ),
        _IconCategory(
          name: l10n.iconCategoryShopping,
          icons: [
            _IconItem('shopping_cart', Icons.shopping_cart, l10n.iconLabelShoppingCart),
            _IconItem('shopping_bag', Icons.shopping_bag, l10n.iconLabelShoppingBag),
            _IconItem('store', Icons.store, l10n.iconLabelStore),
            _IconItem('local_mall', Icons.local_mall, l10n.iconLabelLocalMall),
            _IconItem('local_grocery_store', Icons.local_grocery_store, l10n.iconLabelLocalGroceryStore),
            _IconItem('checkroom', Icons.checkroom, l10n.iconLabelCheckroom),
            _IconItem('watch', Icons.watch, l10n.iconLabelWatch),
            _IconItem('diamond', Icons.diamond, l10n.iconLabelDiamond),
          ],
        ),
        _IconCategory(
          name: l10n.iconCategoryEntertainment,
          icons: [
            _IconItem('movie', Icons.movie, l10n.iconLabelMovie),
            _IconItem('music_note', Icons.music_note, l10n.iconLabelMusicNote),
            _IconItem('sports_esports', Icons.sports_esports, l10n.iconLabelSportsEsports),
            _IconItem('sports_soccer', Icons.sports_soccer, l10n.iconLabelSportsSoccer),
            _IconItem('sports_basketball', Icons.sports_basketball, l10n.iconLabelSportsBasketball),
            _IconItem('theater_comedy', Icons.theater_comedy, l10n.iconLabelTheaterComedy),
            _IconItem('camera_alt', Icons.camera_alt, l10n.iconLabelCameraAlt),
            _IconItem('palette', Icons.palette, l10n.iconLabelPalette),
          ],
        ),
        _IconCategory(
          name: l10n.iconCategoryLife,
          icons: [
            _IconItem('home', Icons.home, l10n.iconLabelHome),
            _IconItem('local_laundry_service', Icons.local_laundry_service, l10n.iconLabelLocalLaundryService),
            _IconItem('cleaning_services', Icons.cleaning_services, l10n.iconLabelCleaningServices),
            _IconItem('plumbing', Icons.plumbing, l10n.iconLabelPlumbing),
            _IconItem('electrical_services', Icons.electrical_services, l10n.iconLabelElectricalServices),
            _IconItem('handyman', Icons.handyman, l10n.iconLabelHandyman),
            _IconItem('pets', Icons.pets, l10n.iconLabelPets),
            _IconItem('child_care', Icons.child_care, l10n.iconLabelChildCare),
          ],
        ),
        _IconCategory(
          name: l10n.iconCategoryHealth,
          icons: [
            _IconItem('local_hospital', Icons.local_hospital, l10n.iconLabelLocalHospital),
            _IconItem('medical_services', Icons.medical_services, l10n.iconLabelMedicalServices),
            _IconItem('local_pharmacy', Icons.local_pharmacy, l10n.iconLabelLocalPharmacy),
            _IconItem('fitness_center', Icons.fitness_center, l10n.iconLabelFitnessCenter),
            _IconItem('spa', Icons.spa, l10n.iconLabelSpa),
            _IconItem('psychology', Icons.psychology, l10n.iconLabelPsychology),
            _IconItem('face', Icons.face, l10n.iconLabelFace),
            _IconItem('content_cut', Icons.content_cut, l10n.iconLabelContentCut),
          ],
        ),
        _IconCategory(
          name: l10n.iconCategoryEducation,
          icons: [
            _IconItem('school', Icons.school, l10n.iconLabelSchool),
            _IconItem('library_books', Icons.library_books, l10n.iconLabelLibraryBooks),
            _IconItem('computer', Icons.computer, l10n.iconLabelComputer),
            _IconItem('phone', Icons.phone, l10n.iconLabelPhone),
            _IconItem('language', Icons.language, l10n.iconLabelLanguage),
            _IconItem('science', Icons.science, l10n.iconLabelScience),
            _IconItem('calculate', Icons.calculate, l10n.iconLabelCalculate),
            _IconItem('brush', Icons.brush, l10n.iconLabelBrush),
          ],
        ),
        _IconCategory(
          name: l10n.iconCategoryOther,
          icons: [
            _IconItem('business', Icons.business, l10n.iconLabelBusiness),
            _IconItem('work', Icons.work, l10n.iconLabelWork),
            _IconItem('flash_on', Icons.flash_on, l10n.iconLabelFlashOn),
            _IconItem('wifi', Icons.wifi, l10n.iconLabelWifi),
            _IconItem('phone_android', Icons.phone_android, l10n.iconLabelPhoneAndroid),
            _IconItem('smoking_rooms', Icons.smoking_rooms, l10n.iconLabelSmokingRooms),
            _IconItem('favorite', Icons.favorite, l10n.iconLabelFavorite),
            _IconItem('category', Icons.category, l10n.iconLabelCategory),
          ],
        ),
      ];
    } else {
      // 收入分类图标
      return [
        _IconCategory(
          name: l10n.iconCategoryWork,
          icons: [
            _IconItem('work', Icons.work, l10n.iconLabelSalary),
            _IconItem('business_center', Icons.business_center, l10n.iconLabelBusinessCenter),
            _IconItem('engineering', Icons.engineering, l10n.iconLabelEngineering),
            _IconItem('design_services', Icons.design_services, l10n.iconLabelDesignServices),
            _IconItem('agriculture', Icons.agriculture, l10n.iconLabelAgriculture),
            _IconItem('construction', Icons.construction, l10n.iconLabelConstruction),
            _IconItem('local_shipping', Icons.local_shipping, l10n.iconLabelLocalShipping),
            _IconItem('restaurant_menu', Icons.restaurant_menu, l10n.iconLabelRestaurantMenu),
          ],
        ),
        _IconCategory(
          name: l10n.iconCategoryFinance,
          icons: [
            _IconItem('account_balance', Icons.account_balance, l10n.iconLabelAccountBalance),
            _IconItem('savings', Icons.savings, l10n.iconLabelSavings),
            _IconItem('trending_up', Icons.trending_up, l10n.iconLabelTrendingUp),
            _IconItem('paid', Icons.paid, l10n.iconLabelPaid),
            _IconItem('currency_exchange', Icons.currency_exchange, l10n.iconLabelCurrencyExchange),
            _IconItem('wallet', Icons.wallet, l10n.iconLabelWallet),
            _IconItem('credit_card', Icons.credit_card, l10n.iconLabelCreditCard),
            _IconItem('account_balance_wallet', Icons.account_balance_wallet, l10n.iconLabelAccountBalanceWallet),
          ],
        ),
        _IconCategory(
          name: l10n.iconCategoryReward,
          icons: [
            _IconItem('card_giftcard', Icons.card_giftcard, l10n.iconLabelCardGiftcard),
            _IconItem('redeem', Icons.redeem, l10n.iconLabelRedeem),
            _IconItem('emoji_events', Icons.emoji_events, l10n.iconLabelEmojiEvents),
            _IconItem('star', Icons.star, l10n.iconLabelStar),
            _IconItem('grade', Icons.grade, l10n.iconLabelGrade),
            _IconItem('loyalty', Icons.loyalty, l10n.iconLabelLoyalty),
            _IconItem('volunteer_activism', Icons.volunteer_activism, l10n.iconLabelVolunteerActivism),
            _IconItem('celebration', Icons.celebration, l10n.iconLabelCelebration),
          ],
        ),
        _IconCategory(
          name: l10n.iconCategoryOther,
          icons: [
            _IconItem('receipt_long', Icons.receipt_long, l10n.iconLabelReceiptLong),
            _IconItem('part_time', Icons.schedule, l10n.iconLabelPartTime),
            _IconItem('undo', Icons.undo, l10n.iconLabelUndo),
            _IconItem('money', Icons.attach_money, l10n.iconLabelMoney),
            _IconItem('apartment', Icons.apartment, l10n.iconLabelApartment),
            _IconItem('handshake', Icons.handshake, l10n.iconLabelHandshake),
            _IconItem('category', Icons.category, l10n.iconLabelCategory),
            _IconItem('help', Icons.help, l10n.iconLabelHelp),
          ],
        ),
      ];
    }
  }
}

class _IconGrid extends StatelessWidget {
  final List<_IconItem> icons;
  final String? selectedIcon;
  final ValueChanged<String> onIconSelected;

  const _IconGrid({
    required this.icons,
    required this.selectedIcon,
    required this.onIconSelected,
  });

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
      ),
      itemCount: icons.length,
      itemBuilder: (context, index) {
        final icon = icons[index];
        final isSelected = selectedIcon == icon.key;

        return InkWell(
          onTap: () => onIconSelected(icon.key),
          child: Container(
            decoration: BoxDecoration(
              color: isSelected
                  ? PiggyTokens.primary(context).withValues(alpha: 0.1)
                  : null,
              border: Border.all(
                color: isSelected
                    ? PiggyTokens.primary(context)
                    : PiggyTokens.border(context),
                width: isSelected ? 2 : 1,
              ),
              borderRadius: BorderRadius.circular(PiggyDimens.radiusSm),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  icon.iconData,
                  size: 32,
                  color: isSelected
                      ? PiggyTokens.primary(context)
                      : PiggyTokens.iconPrimary(context),
                ),
                const SizedBox(height: 4),
                Text(
                  icon.label,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: isSelected
                        ? PiggyTokens.primary(context)
                        : null,
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _IconCategory {
  final String name;
  final List<_IconItem> icons;

  const _IconCategory({
    required this.name,
    required this.icons,
  });
}

class _IconItem {
  final String key;
  final IconData iconData;
  final String label;

  const _IconItem(this.key, this.iconData, this.label);
}
