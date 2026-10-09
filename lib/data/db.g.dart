// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'db.dart';

// ignore_for_file: type=lint
class $LedgersTable extends Ledgers with TableInfo<$LedgersTable, Ledger> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LedgersTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
      'name', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _currencyMeta =
      const VerificationMeta('currency');
  @override
  late final GeneratedColumn<String> currency = GeneratedColumn<String>(
      'currency', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('CNY'));
  static const VerificationMeta _typeMeta = const VerificationMeta('type');
  @override
  late final GeneratedColumn<String> type = GeneratedColumn<String>(
      'type', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('personal'));
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
      'created_at', aliasedName, false,
      type: DriftSqlType.dateTime,
      requiredDuringInsert: false,
      defaultValue: currentDateAndTime);
  static const VerificationMeta _syncIdMeta = const VerificationMeta('syncId');
  @override
  late final GeneratedColumn<String> syncId = GeneratedColumn<String>(
      'sync_id', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _monthStartDayMeta =
      const VerificationMeta('monthStartDay');
  @override
  late final GeneratedColumn<int> monthStartDay = GeneratedColumn<int>(
      'month_start_day', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(1));
  static const VerificationMeta _updatedAtMeta =
      const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
      'updated_at', aliasedName, true,
      type: DriftSqlType.dateTime, requiredDuringInsert: false);
  @override
  List<GeneratedColumn> get $columns =>
      [id, name, currency, type, createdAt, syncId, monthStartDay, updatedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'ledgers';
  @override
  VerificationContext validateIntegrity(Insertable<Ledger> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('name')) {
      context.handle(
          _nameMeta, name.isAcceptableOrUnknown(data['name']!, _nameMeta));
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('currency')) {
      context.handle(_currencyMeta,
          currency.isAcceptableOrUnknown(data['currency']!, _currencyMeta));
    }
    if (data.containsKey('type')) {
      context.handle(
          _typeMeta, type.isAcceptableOrUnknown(data['type']!, _typeMeta));
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    }
    if (data.containsKey('sync_id')) {
      context.handle(_syncIdMeta,
          syncId.isAcceptableOrUnknown(data['sync_id']!, _syncIdMeta));
    }
    if (data.containsKey('month_start_day')) {
      context.handle(
          _monthStartDayMeta,
          monthStartDay.isAcceptableOrUnknown(
              data['month_start_day']!, _monthStartDayMeta));
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta,
          updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Ledger map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Ledger(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      name: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}name'])!,
      currency: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}currency'])!,
      type: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}type'])!,
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}created_at'])!,
      syncId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}sync_id']),
      monthStartDay: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}month_start_day'])!,
      updatedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}updated_at']),
    );
  }

  @override
  $LedgersTable createAlias(String alias) {
    return $LedgersTable(attachedDatabase, alias);
  }
}

class Ledger extends DataClass implements Insertable<Ledger> {
  final int id;
  final String name;
  final String currency;
  final String type;
  final DateTime createdAt;
  final String? syncId;
  final int monthStartDay;

  /// 审计 T1（v40）：本行最后一次被**本设备写**的时刻（UTC epoch）。
  /// NULL = 本设备从未更新过该行（新建即导入的行保持 NULL，语义明确）。
  /// 由数据库触发器 trg_ledgers_touch_updated_at 在普通 UPDATE 时自动维护；
  /// 显式写入不同值（如未来 pull apply 回填远端时间）不会被触发器覆盖。
  /// 用途：本地新旧证据 / 未来 LWW 方向仲裁的基础字段。
  final DateTime? updatedAt;
  const Ledger(
      {required this.id,
      required this.name,
      required this.currency,
      required this.type,
      required this.createdAt,
      this.syncId,
      required this.monthStartDay,
      this.updatedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['name'] = Variable<String>(name);
    map['currency'] = Variable<String>(currency);
    map['type'] = Variable<String>(type);
    map['created_at'] = Variable<DateTime>(createdAt);
    if (!nullToAbsent || syncId != null) {
      map['sync_id'] = Variable<String>(syncId);
    }
    map['month_start_day'] = Variable<int>(monthStartDay);
    if (!nullToAbsent || updatedAt != null) {
      map['updated_at'] = Variable<DateTime>(updatedAt);
    }
    return map;
  }

  LedgersCompanion toCompanion(bool nullToAbsent) {
    return LedgersCompanion(
      id: Value(id),
      name: Value(name),
      currency: Value(currency),
      type: Value(type),
      createdAt: Value(createdAt),
      syncId:
          syncId == null && nullToAbsent ? const Value.absent() : Value(syncId),
      monthStartDay: Value(monthStartDay),
      updatedAt: updatedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(updatedAt),
    );
  }

  factory Ledger.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Ledger(
      id: serializer.fromJson<int>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      currency: serializer.fromJson<String>(json['currency']),
      type: serializer.fromJson<String>(json['type']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      syncId: serializer.fromJson<String?>(json['syncId']),
      monthStartDay: serializer.fromJson<int>(json['monthStartDay']),
      updatedAt: serializer.fromJson<DateTime?>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'name': serializer.toJson<String>(name),
      'currency': serializer.toJson<String>(currency),
      'type': serializer.toJson<String>(type),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'syncId': serializer.toJson<String?>(syncId),
      'monthStartDay': serializer.toJson<int>(monthStartDay),
      'updatedAt': serializer.toJson<DateTime?>(updatedAt),
    };
  }

  Ledger copyWith(
          {int? id,
          String? name,
          String? currency,
          String? type,
          DateTime? createdAt,
          Value<String?> syncId = const Value.absent(),
          int? monthStartDay,
          Value<DateTime?> updatedAt = const Value.absent()}) =>
      Ledger(
        id: id ?? this.id,
        name: name ?? this.name,
        currency: currency ?? this.currency,
        type: type ?? this.type,
        createdAt: createdAt ?? this.createdAt,
        syncId: syncId.present ? syncId.value : this.syncId,
        monthStartDay: monthStartDay ?? this.monthStartDay,
        updatedAt: updatedAt.present ? updatedAt.value : this.updatedAt,
      );
  Ledger copyWithCompanion(LedgersCompanion data) {
    return Ledger(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      currency: data.currency.present ? data.currency.value : this.currency,
      type: data.type.present ? data.type.value : this.type,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      syncId: data.syncId.present ? data.syncId.value : this.syncId,
      monthStartDay: data.monthStartDay.present
          ? data.monthStartDay.value
          : this.monthStartDay,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Ledger(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('currency: $currency, ')
          ..write('type: $type, ')
          ..write('createdAt: $createdAt, ')
          ..write('syncId: $syncId, ')
          ..write('monthStartDay: $monthStartDay, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      id, name, currency, type, createdAt, syncId, monthStartDay, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Ledger &&
          other.id == this.id &&
          other.name == this.name &&
          other.currency == this.currency &&
          other.type == this.type &&
          other.createdAt == this.createdAt &&
          other.syncId == this.syncId &&
          other.monthStartDay == this.monthStartDay &&
          other.updatedAt == this.updatedAt);
}

class LedgersCompanion extends UpdateCompanion<Ledger> {
  final Value<int> id;
  final Value<String> name;
  final Value<String> currency;
  final Value<String> type;
  final Value<DateTime> createdAt;
  final Value<String?> syncId;
  final Value<int> monthStartDay;
  final Value<DateTime?> updatedAt;
  const LedgersCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.currency = const Value.absent(),
    this.type = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.syncId = const Value.absent(),
    this.monthStartDay = const Value.absent(),
    this.updatedAt = const Value.absent(),
  });
  LedgersCompanion.insert({
    this.id = const Value.absent(),
    required String name,
    this.currency = const Value.absent(),
    this.type = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.syncId = const Value.absent(),
    this.monthStartDay = const Value.absent(),
    this.updatedAt = const Value.absent(),
  }) : name = Value(name);
  static Insertable<Ledger> custom({
    Expression<int>? id,
    Expression<String>? name,
    Expression<String>? currency,
    Expression<String>? type,
    Expression<DateTime>? createdAt,
    Expression<String>? syncId,
    Expression<int>? monthStartDay,
    Expression<DateTime>? updatedAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (currency != null) 'currency': currency,
      if (type != null) 'type': type,
      if (createdAt != null) 'created_at': createdAt,
      if (syncId != null) 'sync_id': syncId,
      if (monthStartDay != null) 'month_start_day': monthStartDay,
      if (updatedAt != null) 'updated_at': updatedAt,
    });
  }

  LedgersCompanion copyWith(
      {Value<int>? id,
      Value<String>? name,
      Value<String>? currency,
      Value<String>? type,
      Value<DateTime>? createdAt,
      Value<String?>? syncId,
      Value<int>? monthStartDay,
      Value<DateTime?>? updatedAt}) {
    return LedgersCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      currency: currency ?? this.currency,
      type: type ?? this.type,
      createdAt: createdAt ?? this.createdAt,
      syncId: syncId ?? this.syncId,
      monthStartDay: monthStartDay ?? this.monthStartDay,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (currency.present) {
      map['currency'] = Variable<String>(currency.value);
    }
    if (type.present) {
      map['type'] = Variable<String>(type.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (syncId.present) {
      map['sync_id'] = Variable<String>(syncId.value);
    }
    if (monthStartDay.present) {
      map['month_start_day'] = Variable<int>(monthStartDay.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LedgersCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('currency: $currency, ')
          ..write('type: $type, ')
          ..write('createdAt: $createdAt, ')
          ..write('syncId: $syncId, ')
          ..write('monthStartDay: $monthStartDay, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }
}

class $AccountsTable extends Accounts with TableInfo<$AccountsTable, Account> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AccountsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _ledgerIdMeta =
      const VerificationMeta('ledgerId');
  @override
  late final GeneratedColumn<int> ledgerId = GeneratedColumn<int>(
      'ledger_id', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
      'name', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _typeMeta = const VerificationMeta('type');
  @override
  late final GeneratedColumn<String> type = GeneratedColumn<String>(
      'type', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('cash'));
  static const VerificationMeta _currencyMeta =
      const VerificationMeta('currency');
  @override
  late final GeneratedColumn<String> currency = GeneratedColumn<String>(
      'currency', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('CNY'));
  static const VerificationMeta _initialBalanceMeta =
      const VerificationMeta('initialBalance');
  @override
  late final GeneratedColumn<double> initialBalance = GeneratedColumn<double>(
      'initial_balance', aliasedName, false,
      type: DriftSqlType.double,
      requiredDuringInsert: false,
      defaultValue: const Constant(0.0));
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
      'created_at', aliasedName, true,
      type: DriftSqlType.dateTime, requiredDuringInsert: false);
  static const VerificationMeta _updatedAtMeta =
      const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
      'updated_at', aliasedName, true,
      type: DriftSqlType.dateTime, requiredDuringInsert: false);
  static const VerificationMeta _sortOrderMeta =
      const VerificationMeta('sortOrder');
  @override
  late final GeneratedColumn<int> sortOrder = GeneratedColumn<int>(
      'sort_order', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _creditLimitMeta =
      const VerificationMeta('creditLimit');
  @override
  late final GeneratedColumn<double> creditLimit = GeneratedColumn<double>(
      'credit_limit', aliasedName, true,
      type: DriftSqlType.double, requiredDuringInsert: false);
  static const VerificationMeta _billingDayMeta =
      const VerificationMeta('billingDay');
  @override
  late final GeneratedColumn<int> billingDay = GeneratedColumn<int>(
      'billing_day', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _paymentDueDayMeta =
      const VerificationMeta('paymentDueDay');
  @override
  late final GeneratedColumn<int> paymentDueDay = GeneratedColumn<int>(
      'payment_due_day', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _bankNameMeta =
      const VerificationMeta('bankName');
  @override
  late final GeneratedColumn<String> bankName = GeneratedColumn<String>(
      'bank_name', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _cardLastFourMeta =
      const VerificationMeta('cardLastFour');
  @override
  late final GeneratedColumn<String> cardLastFour = GeneratedColumn<String>(
      'card_last_four', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _noteMeta = const VerificationMeta('note');
  @override
  late final GeneratedColumn<String> note = GeneratedColumn<String>(
      'note', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _syncIdMeta = const VerificationMeta('syncId');
  @override
  late final GeneratedColumn<String> syncId = GeneratedColumn<String>(
      'sync_id', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _hiddenMeta = const VerificationMeta('hidden');
  @override
  late final GeneratedColumn<bool> hidden = GeneratedColumn<bool>(
      'hidden', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("hidden" IN (0, 1))'),
      defaultValue: const Constant(false));
  @override
  List<GeneratedColumn> get $columns => [
        id,
        ledgerId,
        name,
        type,
        currency,
        initialBalance,
        createdAt,
        updatedAt,
        sortOrder,
        creditLimit,
        billingDay,
        paymentDueDay,
        bankName,
        cardLastFour,
        note,
        syncId,
        hidden
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'accounts';
  @override
  VerificationContext validateIntegrity(Insertable<Account> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('ledger_id')) {
      context.handle(_ledgerIdMeta,
          ledgerId.isAcceptableOrUnknown(data['ledger_id']!, _ledgerIdMeta));
    } else if (isInserting) {
      context.missing(_ledgerIdMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
          _nameMeta, name.isAcceptableOrUnknown(data['name']!, _nameMeta));
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('type')) {
      context.handle(
          _typeMeta, type.isAcceptableOrUnknown(data['type']!, _typeMeta));
    }
    if (data.containsKey('currency')) {
      context.handle(_currencyMeta,
          currency.isAcceptableOrUnknown(data['currency']!, _currencyMeta));
    }
    if (data.containsKey('initial_balance')) {
      context.handle(
          _initialBalanceMeta,
          initialBalance.isAcceptableOrUnknown(
              data['initial_balance']!, _initialBalanceMeta));
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta,
          updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
    }
    if (data.containsKey('sort_order')) {
      context.handle(_sortOrderMeta,
          sortOrder.isAcceptableOrUnknown(data['sort_order']!, _sortOrderMeta));
    }
    if (data.containsKey('credit_limit')) {
      context.handle(
          _creditLimitMeta,
          creditLimit.isAcceptableOrUnknown(
              data['credit_limit']!, _creditLimitMeta));
    }
    if (data.containsKey('billing_day')) {
      context.handle(
          _billingDayMeta,
          billingDay.isAcceptableOrUnknown(
              data['billing_day']!, _billingDayMeta));
    }
    if (data.containsKey('payment_due_day')) {
      context.handle(
          _paymentDueDayMeta,
          paymentDueDay.isAcceptableOrUnknown(
              data['payment_due_day']!, _paymentDueDayMeta));
    }
    if (data.containsKey('bank_name')) {
      context.handle(_bankNameMeta,
          bankName.isAcceptableOrUnknown(data['bank_name']!, _bankNameMeta));
    }
    if (data.containsKey('card_last_four')) {
      context.handle(
          _cardLastFourMeta,
          cardLastFour.isAcceptableOrUnknown(
              data['card_last_four']!, _cardLastFourMeta));
    }
    if (data.containsKey('note')) {
      context.handle(
          _noteMeta, note.isAcceptableOrUnknown(data['note']!, _noteMeta));
    }
    if (data.containsKey('sync_id')) {
      context.handle(_syncIdMeta,
          syncId.isAcceptableOrUnknown(data['sync_id']!, _syncIdMeta));
    }
    if (data.containsKey('hidden')) {
      context.handle(_hiddenMeta,
          hidden.isAcceptableOrUnknown(data['hidden']!, _hiddenMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Account map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Account(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      ledgerId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}ledger_id'])!,
      name: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}name'])!,
      type: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}type'])!,
      currency: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}currency'])!,
      initialBalance: attachedDatabase.typeMapping.read(
          DriftSqlType.double, data['${effectivePrefix}initial_balance'])!,
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}created_at']),
      updatedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}updated_at']),
      sortOrder: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}sort_order'])!,
      creditLimit: attachedDatabase.typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}credit_limit']),
      billingDay: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}billing_day']),
      paymentDueDay: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}payment_due_day']),
      bankName: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}bank_name']),
      cardLastFour: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}card_last_four']),
      note: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}note']),
      syncId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}sync_id']),
      hidden: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}hidden'])!,
    );
  }

  @override
  $AccountsTable createAlias(String alias) {
    return $AccountsTable(attachedDatabase, alias);
  }
}

class Account extends DataClass implements Insertable<Account> {
  final int id;
  final int ledgerId;
  final String name;
  final String type;
  final String currency;
  final double initialBalance;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final int sortOrder;
  final double? creditLimit;
  final int? billingDay;
  final int? paymentDueDay;
  final String? bankName;
  final String? cardLastFour;
  final String? note;
  final String? syncId;

  /// 隐藏:true 时该账户不再出现在记账/转账/周期选择器,账户管理页移入「已隐藏」分区。
  /// 仍计入账户余额、净资产、资产构成、净值趋势(.docs/account-archive/01 §二 D1)。
  final bool hidden;
  const Account(
      {required this.id,
      required this.ledgerId,
      required this.name,
      required this.type,
      required this.currency,
      required this.initialBalance,
      this.createdAt,
      this.updatedAt,
      required this.sortOrder,
      this.creditLimit,
      this.billingDay,
      this.paymentDueDay,
      this.bankName,
      this.cardLastFour,
      this.note,
      this.syncId,
      required this.hidden});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['ledger_id'] = Variable<int>(ledgerId);
    map['name'] = Variable<String>(name);
    map['type'] = Variable<String>(type);
    map['currency'] = Variable<String>(currency);
    map['initial_balance'] = Variable<double>(initialBalance);
    if (!nullToAbsent || createdAt != null) {
      map['created_at'] = Variable<DateTime>(createdAt);
    }
    if (!nullToAbsent || updatedAt != null) {
      map['updated_at'] = Variable<DateTime>(updatedAt);
    }
    map['sort_order'] = Variable<int>(sortOrder);
    if (!nullToAbsent || creditLimit != null) {
      map['credit_limit'] = Variable<double>(creditLimit);
    }
    if (!nullToAbsent || billingDay != null) {
      map['billing_day'] = Variable<int>(billingDay);
    }
    if (!nullToAbsent || paymentDueDay != null) {
      map['payment_due_day'] = Variable<int>(paymentDueDay);
    }
    if (!nullToAbsent || bankName != null) {
      map['bank_name'] = Variable<String>(bankName);
    }
    if (!nullToAbsent || cardLastFour != null) {
      map['card_last_four'] = Variable<String>(cardLastFour);
    }
    if (!nullToAbsent || note != null) {
      map['note'] = Variable<String>(note);
    }
    if (!nullToAbsent || syncId != null) {
      map['sync_id'] = Variable<String>(syncId);
    }
    map['hidden'] = Variable<bool>(hidden);
    return map;
  }

  AccountsCompanion toCompanion(bool nullToAbsent) {
    return AccountsCompanion(
      id: Value(id),
      ledgerId: Value(ledgerId),
      name: Value(name),
      type: Value(type),
      currency: Value(currency),
      initialBalance: Value(initialBalance),
      createdAt: createdAt == null && nullToAbsent
          ? const Value.absent()
          : Value(createdAt),
      updatedAt: updatedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(updatedAt),
      sortOrder: Value(sortOrder),
      creditLimit: creditLimit == null && nullToAbsent
          ? const Value.absent()
          : Value(creditLimit),
      billingDay: billingDay == null && nullToAbsent
          ? const Value.absent()
          : Value(billingDay),
      paymentDueDay: paymentDueDay == null && nullToAbsent
          ? const Value.absent()
          : Value(paymentDueDay),
      bankName: bankName == null && nullToAbsent
          ? const Value.absent()
          : Value(bankName),
      cardLastFour: cardLastFour == null && nullToAbsent
          ? const Value.absent()
          : Value(cardLastFour),
      note: note == null && nullToAbsent ? const Value.absent() : Value(note),
      syncId:
          syncId == null && nullToAbsent ? const Value.absent() : Value(syncId),
      hidden: Value(hidden),
    );
  }

  factory Account.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Account(
      id: serializer.fromJson<int>(json['id']),
      ledgerId: serializer.fromJson<int>(json['ledgerId']),
      name: serializer.fromJson<String>(json['name']),
      type: serializer.fromJson<String>(json['type']),
      currency: serializer.fromJson<String>(json['currency']),
      initialBalance: serializer.fromJson<double>(json['initialBalance']),
      createdAt: serializer.fromJson<DateTime?>(json['createdAt']),
      updatedAt: serializer.fromJson<DateTime?>(json['updatedAt']),
      sortOrder: serializer.fromJson<int>(json['sortOrder']),
      creditLimit: serializer.fromJson<double?>(json['creditLimit']),
      billingDay: serializer.fromJson<int?>(json['billingDay']),
      paymentDueDay: serializer.fromJson<int?>(json['paymentDueDay']),
      bankName: serializer.fromJson<String?>(json['bankName']),
      cardLastFour: serializer.fromJson<String?>(json['cardLastFour']),
      note: serializer.fromJson<String?>(json['note']),
      syncId: serializer.fromJson<String?>(json['syncId']),
      hidden: serializer.fromJson<bool>(json['hidden']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'ledgerId': serializer.toJson<int>(ledgerId),
      'name': serializer.toJson<String>(name),
      'type': serializer.toJson<String>(type),
      'currency': serializer.toJson<String>(currency),
      'initialBalance': serializer.toJson<double>(initialBalance),
      'createdAt': serializer.toJson<DateTime?>(createdAt),
      'updatedAt': serializer.toJson<DateTime?>(updatedAt),
      'sortOrder': serializer.toJson<int>(sortOrder),
      'creditLimit': serializer.toJson<double?>(creditLimit),
      'billingDay': serializer.toJson<int?>(billingDay),
      'paymentDueDay': serializer.toJson<int?>(paymentDueDay),
      'bankName': serializer.toJson<String?>(bankName),
      'cardLastFour': serializer.toJson<String?>(cardLastFour),
      'note': serializer.toJson<String?>(note),
      'syncId': serializer.toJson<String?>(syncId),
      'hidden': serializer.toJson<bool>(hidden),
    };
  }

  Account copyWith(
          {int? id,
          int? ledgerId,
          String? name,
          String? type,
          String? currency,
          double? initialBalance,
          Value<DateTime?> createdAt = const Value.absent(),
          Value<DateTime?> updatedAt = const Value.absent(),
          int? sortOrder,
          Value<double?> creditLimit = const Value.absent(),
          Value<int?> billingDay = const Value.absent(),
          Value<int?> paymentDueDay = const Value.absent(),
          Value<String?> bankName = const Value.absent(),
          Value<String?> cardLastFour = const Value.absent(),
          Value<String?> note = const Value.absent(),
          Value<String?> syncId = const Value.absent(),
          bool? hidden}) =>
      Account(
        id: id ?? this.id,
        ledgerId: ledgerId ?? this.ledgerId,
        name: name ?? this.name,
        type: type ?? this.type,
        currency: currency ?? this.currency,
        initialBalance: initialBalance ?? this.initialBalance,
        createdAt: createdAt.present ? createdAt.value : this.createdAt,
        updatedAt: updatedAt.present ? updatedAt.value : this.updatedAt,
        sortOrder: sortOrder ?? this.sortOrder,
        creditLimit: creditLimit.present ? creditLimit.value : this.creditLimit,
        billingDay: billingDay.present ? billingDay.value : this.billingDay,
        paymentDueDay:
            paymentDueDay.present ? paymentDueDay.value : this.paymentDueDay,
        bankName: bankName.present ? bankName.value : this.bankName,
        cardLastFour:
            cardLastFour.present ? cardLastFour.value : this.cardLastFour,
        note: note.present ? note.value : this.note,
        syncId: syncId.present ? syncId.value : this.syncId,
        hidden: hidden ?? this.hidden,
      );
  Account copyWithCompanion(AccountsCompanion data) {
    return Account(
      id: data.id.present ? data.id.value : this.id,
      ledgerId: data.ledgerId.present ? data.ledgerId.value : this.ledgerId,
      name: data.name.present ? data.name.value : this.name,
      type: data.type.present ? data.type.value : this.type,
      currency: data.currency.present ? data.currency.value : this.currency,
      initialBalance: data.initialBalance.present
          ? data.initialBalance.value
          : this.initialBalance,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      sortOrder: data.sortOrder.present ? data.sortOrder.value : this.sortOrder,
      creditLimit:
          data.creditLimit.present ? data.creditLimit.value : this.creditLimit,
      billingDay:
          data.billingDay.present ? data.billingDay.value : this.billingDay,
      paymentDueDay: data.paymentDueDay.present
          ? data.paymentDueDay.value
          : this.paymentDueDay,
      bankName: data.bankName.present ? data.bankName.value : this.bankName,
      cardLastFour: data.cardLastFour.present
          ? data.cardLastFour.value
          : this.cardLastFour,
      note: data.note.present ? data.note.value : this.note,
      syncId: data.syncId.present ? data.syncId.value : this.syncId,
      hidden: data.hidden.present ? data.hidden.value : this.hidden,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Account(')
          ..write('id: $id, ')
          ..write('ledgerId: $ledgerId, ')
          ..write('name: $name, ')
          ..write('type: $type, ')
          ..write('currency: $currency, ')
          ..write('initialBalance: $initialBalance, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('creditLimit: $creditLimit, ')
          ..write('billingDay: $billingDay, ')
          ..write('paymentDueDay: $paymentDueDay, ')
          ..write('bankName: $bankName, ')
          ..write('cardLastFour: $cardLastFour, ')
          ..write('note: $note, ')
          ..write('syncId: $syncId, ')
          ..write('hidden: $hidden')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      id,
      ledgerId,
      name,
      type,
      currency,
      initialBalance,
      createdAt,
      updatedAt,
      sortOrder,
      creditLimit,
      billingDay,
      paymentDueDay,
      bankName,
      cardLastFour,
      note,
      syncId,
      hidden);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Account &&
          other.id == this.id &&
          other.ledgerId == this.ledgerId &&
          other.name == this.name &&
          other.type == this.type &&
          other.currency == this.currency &&
          other.initialBalance == this.initialBalance &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt &&
          other.sortOrder == this.sortOrder &&
          other.creditLimit == this.creditLimit &&
          other.billingDay == this.billingDay &&
          other.paymentDueDay == this.paymentDueDay &&
          other.bankName == this.bankName &&
          other.cardLastFour == this.cardLastFour &&
          other.note == this.note &&
          other.syncId == this.syncId &&
          other.hidden == this.hidden);
}

class AccountsCompanion extends UpdateCompanion<Account> {
  final Value<int> id;
  final Value<int> ledgerId;
  final Value<String> name;
  final Value<String> type;
  final Value<String> currency;
  final Value<double> initialBalance;
  final Value<DateTime?> createdAt;
  final Value<DateTime?> updatedAt;
  final Value<int> sortOrder;
  final Value<double?> creditLimit;
  final Value<int?> billingDay;
  final Value<int?> paymentDueDay;
  final Value<String?> bankName;
  final Value<String?> cardLastFour;
  final Value<String?> note;
  final Value<String?> syncId;
  final Value<bool> hidden;
  const AccountsCompanion({
    this.id = const Value.absent(),
    this.ledgerId = const Value.absent(),
    this.name = const Value.absent(),
    this.type = const Value.absent(),
    this.currency = const Value.absent(),
    this.initialBalance = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.sortOrder = const Value.absent(),
    this.creditLimit = const Value.absent(),
    this.billingDay = const Value.absent(),
    this.paymentDueDay = const Value.absent(),
    this.bankName = const Value.absent(),
    this.cardLastFour = const Value.absent(),
    this.note = const Value.absent(),
    this.syncId = const Value.absent(),
    this.hidden = const Value.absent(),
  });
  AccountsCompanion.insert({
    this.id = const Value.absent(),
    required int ledgerId,
    required String name,
    this.type = const Value.absent(),
    this.currency = const Value.absent(),
    this.initialBalance = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.sortOrder = const Value.absent(),
    this.creditLimit = const Value.absent(),
    this.billingDay = const Value.absent(),
    this.paymentDueDay = const Value.absent(),
    this.bankName = const Value.absent(),
    this.cardLastFour = const Value.absent(),
    this.note = const Value.absent(),
    this.syncId = const Value.absent(),
    this.hidden = const Value.absent(),
  })  : ledgerId = Value(ledgerId),
        name = Value(name);
  static Insertable<Account> custom({
    Expression<int>? id,
    Expression<int>? ledgerId,
    Expression<String>? name,
    Expression<String>? type,
    Expression<String>? currency,
    Expression<double>? initialBalance,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? updatedAt,
    Expression<int>? sortOrder,
    Expression<double>? creditLimit,
    Expression<int>? billingDay,
    Expression<int>? paymentDueDay,
    Expression<String>? bankName,
    Expression<String>? cardLastFour,
    Expression<String>? note,
    Expression<String>? syncId,
    Expression<bool>? hidden,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (ledgerId != null) 'ledger_id': ledgerId,
      if (name != null) 'name': name,
      if (type != null) 'type': type,
      if (currency != null) 'currency': currency,
      if (initialBalance != null) 'initial_balance': initialBalance,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (sortOrder != null) 'sort_order': sortOrder,
      if (creditLimit != null) 'credit_limit': creditLimit,
      if (billingDay != null) 'billing_day': billingDay,
      if (paymentDueDay != null) 'payment_due_day': paymentDueDay,
      if (bankName != null) 'bank_name': bankName,
      if (cardLastFour != null) 'card_last_four': cardLastFour,
      if (note != null) 'note': note,
      if (syncId != null) 'sync_id': syncId,
      if (hidden != null) 'hidden': hidden,
    });
  }

  AccountsCompanion copyWith(
      {Value<int>? id,
      Value<int>? ledgerId,
      Value<String>? name,
      Value<String>? type,
      Value<String>? currency,
      Value<double>? initialBalance,
      Value<DateTime?>? createdAt,
      Value<DateTime?>? updatedAt,
      Value<int>? sortOrder,
      Value<double?>? creditLimit,
      Value<int?>? billingDay,
      Value<int?>? paymentDueDay,
      Value<String?>? bankName,
      Value<String?>? cardLastFour,
      Value<String?>? note,
      Value<String?>? syncId,
      Value<bool>? hidden}) {
    return AccountsCompanion(
      id: id ?? this.id,
      ledgerId: ledgerId ?? this.ledgerId,
      name: name ?? this.name,
      type: type ?? this.type,
      currency: currency ?? this.currency,
      initialBalance: initialBalance ?? this.initialBalance,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      sortOrder: sortOrder ?? this.sortOrder,
      creditLimit: creditLimit ?? this.creditLimit,
      billingDay: billingDay ?? this.billingDay,
      paymentDueDay: paymentDueDay ?? this.paymentDueDay,
      bankName: bankName ?? this.bankName,
      cardLastFour: cardLastFour ?? this.cardLastFour,
      note: note ?? this.note,
      syncId: syncId ?? this.syncId,
      hidden: hidden ?? this.hidden,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (ledgerId.present) {
      map['ledger_id'] = Variable<int>(ledgerId.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (type.present) {
      map['type'] = Variable<String>(type.value);
    }
    if (currency.present) {
      map['currency'] = Variable<String>(currency.value);
    }
    if (initialBalance.present) {
      map['initial_balance'] = Variable<double>(initialBalance.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (sortOrder.present) {
      map['sort_order'] = Variable<int>(sortOrder.value);
    }
    if (creditLimit.present) {
      map['credit_limit'] = Variable<double>(creditLimit.value);
    }
    if (billingDay.present) {
      map['billing_day'] = Variable<int>(billingDay.value);
    }
    if (paymentDueDay.present) {
      map['payment_due_day'] = Variable<int>(paymentDueDay.value);
    }
    if (bankName.present) {
      map['bank_name'] = Variable<String>(bankName.value);
    }
    if (cardLastFour.present) {
      map['card_last_four'] = Variable<String>(cardLastFour.value);
    }
    if (note.present) {
      map['note'] = Variable<String>(note.value);
    }
    if (syncId.present) {
      map['sync_id'] = Variable<String>(syncId.value);
    }
    if (hidden.present) {
      map['hidden'] = Variable<bool>(hidden.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AccountsCompanion(')
          ..write('id: $id, ')
          ..write('ledgerId: $ledgerId, ')
          ..write('name: $name, ')
          ..write('type: $type, ')
          ..write('currency: $currency, ')
          ..write('initialBalance: $initialBalance, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('creditLimit: $creditLimit, ')
          ..write('billingDay: $billingDay, ')
          ..write('paymentDueDay: $paymentDueDay, ')
          ..write('bankName: $bankName, ')
          ..write('cardLastFour: $cardLastFour, ')
          ..write('note: $note, ')
          ..write('syncId: $syncId, ')
          ..write('hidden: $hidden')
          ..write(')'))
        .toString();
  }
}

class $HoldingsTable extends Holdings with TableInfo<$HoldingsTable, Holding> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $HoldingsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _ledgerIdMeta =
      const VerificationMeta('ledgerId');
  @override
  late final GeneratedColumn<int> ledgerId = GeneratedColumn<int>(
      'ledger_id', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _accountIdMeta =
      const VerificationMeta('accountId');
  @override
  late final GeneratedColumn<int> accountId = GeneratedColumn<int>(
      'account_id', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
      'name', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _symbolMeta = const VerificationMeta('symbol');
  @override
  late final GeneratedColumn<String> symbol = GeneratedColumn<String>(
      'symbol', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _marketMeta = const VerificationMeta('market');
  @override
  late final GeneratedColumn<String> market = GeneratedColumn<String>(
      'market', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _assetClassMeta =
      const VerificationMeta('assetClass');
  @override
  late final GeneratedColumn<String> assetClass = GeneratedColumn<String>(
      'asset_class', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('other'));
  static const VerificationMeta _currencyMeta =
      const VerificationMeta('currency');
  @override
  late final GeneratedColumn<String> currency = GeneratedColumn<String>(
      'currency', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('CNY'));
  static const VerificationMeta _quantityMeta =
      const VerificationMeta('quantity');
  @override
  late final GeneratedColumn<double> quantity = GeneratedColumn<double>(
      'quantity', aliasedName, false,
      type: DriftSqlType.double,
      requiredDuringInsert: false,
      defaultValue: const Constant(0.0));
  static const VerificationMeta _unitCostMeta =
      const VerificationMeta('unitCost');
  @override
  late final GeneratedColumn<double> unitCost = GeneratedColumn<double>(
      'unit_cost', aliasedName, false,
      type: DriftSqlType.double,
      requiredDuringInsert: false,
      defaultValue: const Constant(0.0));
  static const VerificationMeta _unitPriceMeta =
      const VerificationMeta('unitPrice');
  @override
  late final GeneratedColumn<double> unitPrice = GeneratedColumn<double>(
      'unit_price', aliasedName, false,
      type: DriftSqlType.double,
      requiredDuringInsert: false,
      defaultValue: const Constant(0.0));
  static const VerificationMeta _autoQuoteMeta =
      const VerificationMeta('autoQuote');
  @override
  late final GeneratedColumn<bool> autoQuote = GeneratedColumn<bool>(
      'auto_quote', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("auto_quote" IN (0, 1))'),
      defaultValue: const Constant(false));
  static const VerificationMeta _noteMeta = const VerificationMeta('note');
  @override
  late final GeneratedColumn<String> note = GeneratedColumn<String>(
      'note', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _sortOrderMeta =
      const VerificationMeta('sortOrder');
  @override
  late final GeneratedColumn<int> sortOrder = GeneratedColumn<int>(
      'sort_order', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _syncIdMeta = const VerificationMeta('syncId');
  @override
  late final GeneratedColumn<String> syncId = GeneratedColumn<String>(
      'sync_id', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
      'created_at', aliasedName, true,
      type: DriftSqlType.dateTime, requiredDuringInsert: false);
  static const VerificationMeta _updatedAtMeta =
      const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
      'updated_at', aliasedName, true,
      type: DriftSqlType.dateTime, requiredDuringInsert: false);
  static const VerificationMeta _quotePriceMeta =
      const VerificationMeta('quotePrice');
  @override
  late final GeneratedColumn<double> quotePrice = GeneratedColumn<double>(
      'quote_price', aliasedName, true,
      type: DriftSqlType.double, requiredDuringInsert: false);
  static const VerificationMeta _quoteFetchedAtMeta =
      const VerificationMeta('quoteFetchedAt');
  @override
  late final GeneratedColumn<DateTime> quoteFetchedAt =
      GeneratedColumn<DateTime>('quote_fetched_at', aliasedName, true,
          type: DriftSqlType.dateTime, requiredDuringInsert: false);
  static const VerificationMeta _quoteSourceIdMeta =
      const VerificationMeta('quoteSourceId');
  @override
  late final GeneratedColumn<String> quoteSourceId = GeneratedColumn<String>(
      'quote_source_id', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  @override
  List<GeneratedColumn> get $columns => [
        id,
        ledgerId,
        accountId,
        name,
        symbol,
        market,
        assetClass,
        currency,
        quantity,
        unitCost,
        unitPrice,
        autoQuote,
        note,
        sortOrder,
        syncId,
        createdAt,
        updatedAt,
        quotePrice,
        quoteFetchedAt,
        quoteSourceId
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'holdings';
  @override
  VerificationContext validateIntegrity(Insertable<Holding> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('ledger_id')) {
      context.handle(_ledgerIdMeta,
          ledgerId.isAcceptableOrUnknown(data['ledger_id']!, _ledgerIdMeta));
    }
    if (data.containsKey('account_id')) {
      context.handle(_accountIdMeta,
          accountId.isAcceptableOrUnknown(data['account_id']!, _accountIdMeta));
    } else if (isInserting) {
      context.missing(_accountIdMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
          _nameMeta, name.isAcceptableOrUnknown(data['name']!, _nameMeta));
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('symbol')) {
      context.handle(_symbolMeta,
          symbol.isAcceptableOrUnknown(data['symbol']!, _symbolMeta));
    }
    if (data.containsKey('market')) {
      context.handle(_marketMeta,
          market.isAcceptableOrUnknown(data['market']!, _marketMeta));
    }
    if (data.containsKey('asset_class')) {
      context.handle(
          _assetClassMeta,
          assetClass.isAcceptableOrUnknown(
              data['asset_class']!, _assetClassMeta));
    }
    if (data.containsKey('currency')) {
      context.handle(_currencyMeta,
          currency.isAcceptableOrUnknown(data['currency']!, _currencyMeta));
    }
    if (data.containsKey('quantity')) {
      context.handle(_quantityMeta,
          quantity.isAcceptableOrUnknown(data['quantity']!, _quantityMeta));
    }
    if (data.containsKey('unit_cost')) {
      context.handle(_unitCostMeta,
          unitCost.isAcceptableOrUnknown(data['unit_cost']!, _unitCostMeta));
    }
    if (data.containsKey('unit_price')) {
      context.handle(_unitPriceMeta,
          unitPrice.isAcceptableOrUnknown(data['unit_price']!, _unitPriceMeta));
    }
    if (data.containsKey('auto_quote')) {
      context.handle(_autoQuoteMeta,
          autoQuote.isAcceptableOrUnknown(data['auto_quote']!, _autoQuoteMeta));
    }
    if (data.containsKey('note')) {
      context.handle(
          _noteMeta, note.isAcceptableOrUnknown(data['note']!, _noteMeta));
    }
    if (data.containsKey('sort_order')) {
      context.handle(_sortOrderMeta,
          sortOrder.isAcceptableOrUnknown(data['sort_order']!, _sortOrderMeta));
    }
    if (data.containsKey('sync_id')) {
      context.handle(_syncIdMeta,
          syncId.isAcceptableOrUnknown(data['sync_id']!, _syncIdMeta));
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta,
          updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
    }
    if (data.containsKey('quote_price')) {
      context.handle(
          _quotePriceMeta,
          quotePrice.isAcceptableOrUnknown(
              data['quote_price']!, _quotePriceMeta));
    }
    if (data.containsKey('quote_fetched_at')) {
      context.handle(
          _quoteFetchedAtMeta,
          quoteFetchedAt.isAcceptableOrUnknown(
              data['quote_fetched_at']!, _quoteFetchedAtMeta));
    }
    if (data.containsKey('quote_source_id')) {
      context.handle(
          _quoteSourceIdMeta,
          quoteSourceId.isAcceptableOrUnknown(
              data['quote_source_id']!, _quoteSourceIdMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Holding map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Holding(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      ledgerId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}ledger_id'])!,
      accountId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}account_id'])!,
      name: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}name'])!,
      symbol: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}symbol']),
      market: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}market']),
      assetClass: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}asset_class'])!,
      currency: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}currency'])!,
      quantity: attachedDatabase.typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}quantity'])!,
      unitCost: attachedDatabase.typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}unit_cost'])!,
      unitPrice: attachedDatabase.typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}unit_price'])!,
      autoQuote: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}auto_quote'])!,
      note: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}note']),
      sortOrder: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}sort_order'])!,
      syncId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}sync_id']),
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}created_at']),
      updatedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}updated_at']),
      quotePrice: attachedDatabase.typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}quote_price']),
      quoteFetchedAt: attachedDatabase.typeMapping.read(
          DriftSqlType.dateTime, data['${effectivePrefix}quote_fetched_at']),
      quoteSourceId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}quote_source_id']),
    );
  }

  @override
  $HoldingsTable createAlias(String alias) {
    return $HoldingsTable(attachedDatabase, alias);
  }
}

class Holding extends DataClass implements Insertable<Holding> {
  final int id;

  /// 与 accounts 同型的 legacy 列（恒 0）：保留只为两表结构对称与未来按账本
  /// 切分的余地，当前**所有查询都按 [accountId] 走**，不要拿它当业务维度。
  final int ledgerId;

  /// 所属投资账户（`accounts.id`）。账户是 user-global，本表随之为 user-global。
  final int accountId;

  /// 持仓名称（如「贵州茅台」「纳斯达克100ETF」）
  final String name;

  /// 行情代码（如 `600519` / `AAPL` / `BTC`）。手填版可为空 = 只当备注用。
  final String? symbol;

  /// 行情市场标识：`SH` / `SZ` / `HK` / `US` / `FUND` / `CRYPTO`。
  /// 手填版不做校验（用户自填），但**一旦接行情源它就是路由键** —— 行情源按
  /// 它决定「这个代码归哪家行情商、用哪条代码规范化规则」。
  final String? market;

  /// 资产类别：`stock` / `fund` / `bond` / `crypto` / `other`（UI 分组与图标）。
  final String assetClass;

  /// 持仓计价币种。**可不同于账户币种**（如人民币账户持有美股）：
  /// 进账户金额前先按汇率折算到账户币种，缺汇率的持仓整条剔除（见 holding_metrics）。
  final String currency;

  /// 持有份额
  final double quantity;

  /// 单位成本（手填，可同步）
  final double unitCost;

  /// 手填当前单位净值（**用户数据、可同步**）。行情可用时展示层走「生效价」
  /// 覆盖它，但本列不清空 —— 行情失效 / 未配置时自动回退，保证可逆。
  final double unitPrice;

  /// 该笔是否参与行情自动刷新（默认 false = 始终用手填净值；可同步）。
  final bool autoQuote;
  final String? note;

  /// 账户内持仓排序，数字越小越靠前
  final int sortOrder;

  /// 跨设备同步唯一标识 (UUID)
  final String? syncId;
  final DateTime? createdAt;

  /// 本地审计时间。**不进快照 / 不进指纹**（与 accounts 同款），因此行情缓存
  /// 写入被 updated_at 触碰触发器顺带刷新也无副作用。
  final DateTime? updatedAt;

  /// 行情源返回的最新单位价（NULL = 从未拉到过行情）
  final double? quotePrice;

  /// 行情拉到时刻（用于「生效价」的 TTL 判定与 UI 展示「更新于 …」）
  final DateTime? quoteFetchedAt;

  /// 提供该行情的行情源标识（如 `manual` / 将来的 `eastmoney`）；换源后旧缓存
  /// 是否仍可用由此列与当前选中源比对决定。
  final String? quoteSourceId;
  const Holding(
      {required this.id,
      required this.ledgerId,
      required this.accountId,
      required this.name,
      this.symbol,
      this.market,
      required this.assetClass,
      required this.currency,
      required this.quantity,
      required this.unitCost,
      required this.unitPrice,
      required this.autoQuote,
      this.note,
      required this.sortOrder,
      this.syncId,
      this.createdAt,
      this.updatedAt,
      this.quotePrice,
      this.quoteFetchedAt,
      this.quoteSourceId});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['ledger_id'] = Variable<int>(ledgerId);
    map['account_id'] = Variable<int>(accountId);
    map['name'] = Variable<String>(name);
    if (!nullToAbsent || symbol != null) {
      map['symbol'] = Variable<String>(symbol);
    }
    if (!nullToAbsent || market != null) {
      map['market'] = Variable<String>(market);
    }
    map['asset_class'] = Variable<String>(assetClass);
    map['currency'] = Variable<String>(currency);
    map['quantity'] = Variable<double>(quantity);
    map['unit_cost'] = Variable<double>(unitCost);
    map['unit_price'] = Variable<double>(unitPrice);
    map['auto_quote'] = Variable<bool>(autoQuote);
    if (!nullToAbsent || note != null) {
      map['note'] = Variable<String>(note);
    }
    map['sort_order'] = Variable<int>(sortOrder);
    if (!nullToAbsent || syncId != null) {
      map['sync_id'] = Variable<String>(syncId);
    }
    if (!nullToAbsent || createdAt != null) {
      map['created_at'] = Variable<DateTime>(createdAt);
    }
    if (!nullToAbsent || updatedAt != null) {
      map['updated_at'] = Variable<DateTime>(updatedAt);
    }
    if (!nullToAbsent || quotePrice != null) {
      map['quote_price'] = Variable<double>(quotePrice);
    }
    if (!nullToAbsent || quoteFetchedAt != null) {
      map['quote_fetched_at'] = Variable<DateTime>(quoteFetchedAt);
    }
    if (!nullToAbsent || quoteSourceId != null) {
      map['quote_source_id'] = Variable<String>(quoteSourceId);
    }
    return map;
  }

  HoldingsCompanion toCompanion(bool nullToAbsent) {
    return HoldingsCompanion(
      id: Value(id),
      ledgerId: Value(ledgerId),
      accountId: Value(accountId),
      name: Value(name),
      symbol:
          symbol == null && nullToAbsent ? const Value.absent() : Value(symbol),
      market:
          market == null && nullToAbsent ? const Value.absent() : Value(market),
      assetClass: Value(assetClass),
      currency: Value(currency),
      quantity: Value(quantity),
      unitCost: Value(unitCost),
      unitPrice: Value(unitPrice),
      autoQuote: Value(autoQuote),
      note: note == null && nullToAbsent ? const Value.absent() : Value(note),
      sortOrder: Value(sortOrder),
      syncId:
          syncId == null && nullToAbsent ? const Value.absent() : Value(syncId),
      createdAt: createdAt == null && nullToAbsent
          ? const Value.absent()
          : Value(createdAt),
      updatedAt: updatedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(updatedAt),
      quotePrice: quotePrice == null && nullToAbsent
          ? const Value.absent()
          : Value(quotePrice),
      quoteFetchedAt: quoteFetchedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(quoteFetchedAt),
      quoteSourceId: quoteSourceId == null && nullToAbsent
          ? const Value.absent()
          : Value(quoteSourceId),
    );
  }

  factory Holding.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Holding(
      id: serializer.fromJson<int>(json['id']),
      ledgerId: serializer.fromJson<int>(json['ledgerId']),
      accountId: serializer.fromJson<int>(json['accountId']),
      name: serializer.fromJson<String>(json['name']),
      symbol: serializer.fromJson<String?>(json['symbol']),
      market: serializer.fromJson<String?>(json['market']),
      assetClass: serializer.fromJson<String>(json['assetClass']),
      currency: serializer.fromJson<String>(json['currency']),
      quantity: serializer.fromJson<double>(json['quantity']),
      unitCost: serializer.fromJson<double>(json['unitCost']),
      unitPrice: serializer.fromJson<double>(json['unitPrice']),
      autoQuote: serializer.fromJson<bool>(json['autoQuote']),
      note: serializer.fromJson<String?>(json['note']),
      sortOrder: serializer.fromJson<int>(json['sortOrder']),
      syncId: serializer.fromJson<String?>(json['syncId']),
      createdAt: serializer.fromJson<DateTime?>(json['createdAt']),
      updatedAt: serializer.fromJson<DateTime?>(json['updatedAt']),
      quotePrice: serializer.fromJson<double?>(json['quotePrice']),
      quoteFetchedAt: serializer.fromJson<DateTime?>(json['quoteFetchedAt']),
      quoteSourceId: serializer.fromJson<String?>(json['quoteSourceId']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'ledgerId': serializer.toJson<int>(ledgerId),
      'accountId': serializer.toJson<int>(accountId),
      'name': serializer.toJson<String>(name),
      'symbol': serializer.toJson<String?>(symbol),
      'market': serializer.toJson<String?>(market),
      'assetClass': serializer.toJson<String>(assetClass),
      'currency': serializer.toJson<String>(currency),
      'quantity': serializer.toJson<double>(quantity),
      'unitCost': serializer.toJson<double>(unitCost),
      'unitPrice': serializer.toJson<double>(unitPrice),
      'autoQuote': serializer.toJson<bool>(autoQuote),
      'note': serializer.toJson<String?>(note),
      'sortOrder': serializer.toJson<int>(sortOrder),
      'syncId': serializer.toJson<String?>(syncId),
      'createdAt': serializer.toJson<DateTime?>(createdAt),
      'updatedAt': serializer.toJson<DateTime?>(updatedAt),
      'quotePrice': serializer.toJson<double?>(quotePrice),
      'quoteFetchedAt': serializer.toJson<DateTime?>(quoteFetchedAt),
      'quoteSourceId': serializer.toJson<String?>(quoteSourceId),
    };
  }

  Holding copyWith(
          {int? id,
          int? ledgerId,
          int? accountId,
          String? name,
          Value<String?> symbol = const Value.absent(),
          Value<String?> market = const Value.absent(),
          String? assetClass,
          String? currency,
          double? quantity,
          double? unitCost,
          double? unitPrice,
          bool? autoQuote,
          Value<String?> note = const Value.absent(),
          int? sortOrder,
          Value<String?> syncId = const Value.absent(),
          Value<DateTime?> createdAt = const Value.absent(),
          Value<DateTime?> updatedAt = const Value.absent(),
          Value<double?> quotePrice = const Value.absent(),
          Value<DateTime?> quoteFetchedAt = const Value.absent(),
          Value<String?> quoteSourceId = const Value.absent()}) =>
      Holding(
        id: id ?? this.id,
        ledgerId: ledgerId ?? this.ledgerId,
        accountId: accountId ?? this.accountId,
        name: name ?? this.name,
        symbol: symbol.present ? symbol.value : this.symbol,
        market: market.present ? market.value : this.market,
        assetClass: assetClass ?? this.assetClass,
        currency: currency ?? this.currency,
        quantity: quantity ?? this.quantity,
        unitCost: unitCost ?? this.unitCost,
        unitPrice: unitPrice ?? this.unitPrice,
        autoQuote: autoQuote ?? this.autoQuote,
        note: note.present ? note.value : this.note,
        sortOrder: sortOrder ?? this.sortOrder,
        syncId: syncId.present ? syncId.value : this.syncId,
        createdAt: createdAt.present ? createdAt.value : this.createdAt,
        updatedAt: updatedAt.present ? updatedAt.value : this.updatedAt,
        quotePrice: quotePrice.present ? quotePrice.value : this.quotePrice,
        quoteFetchedAt:
            quoteFetchedAt.present ? quoteFetchedAt.value : this.quoteFetchedAt,
        quoteSourceId:
            quoteSourceId.present ? quoteSourceId.value : this.quoteSourceId,
      );
  Holding copyWithCompanion(HoldingsCompanion data) {
    return Holding(
      id: data.id.present ? data.id.value : this.id,
      ledgerId: data.ledgerId.present ? data.ledgerId.value : this.ledgerId,
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      name: data.name.present ? data.name.value : this.name,
      symbol: data.symbol.present ? data.symbol.value : this.symbol,
      market: data.market.present ? data.market.value : this.market,
      assetClass:
          data.assetClass.present ? data.assetClass.value : this.assetClass,
      currency: data.currency.present ? data.currency.value : this.currency,
      quantity: data.quantity.present ? data.quantity.value : this.quantity,
      unitCost: data.unitCost.present ? data.unitCost.value : this.unitCost,
      unitPrice: data.unitPrice.present ? data.unitPrice.value : this.unitPrice,
      autoQuote: data.autoQuote.present ? data.autoQuote.value : this.autoQuote,
      note: data.note.present ? data.note.value : this.note,
      sortOrder: data.sortOrder.present ? data.sortOrder.value : this.sortOrder,
      syncId: data.syncId.present ? data.syncId.value : this.syncId,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      quotePrice:
          data.quotePrice.present ? data.quotePrice.value : this.quotePrice,
      quoteFetchedAt: data.quoteFetchedAt.present
          ? data.quoteFetchedAt.value
          : this.quoteFetchedAt,
      quoteSourceId: data.quoteSourceId.present
          ? data.quoteSourceId.value
          : this.quoteSourceId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Holding(')
          ..write('id: $id, ')
          ..write('ledgerId: $ledgerId, ')
          ..write('accountId: $accountId, ')
          ..write('name: $name, ')
          ..write('symbol: $symbol, ')
          ..write('market: $market, ')
          ..write('assetClass: $assetClass, ')
          ..write('currency: $currency, ')
          ..write('quantity: $quantity, ')
          ..write('unitCost: $unitCost, ')
          ..write('unitPrice: $unitPrice, ')
          ..write('autoQuote: $autoQuote, ')
          ..write('note: $note, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('syncId: $syncId, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('quotePrice: $quotePrice, ')
          ..write('quoteFetchedAt: $quoteFetchedAt, ')
          ..write('quoteSourceId: $quoteSourceId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      id,
      ledgerId,
      accountId,
      name,
      symbol,
      market,
      assetClass,
      currency,
      quantity,
      unitCost,
      unitPrice,
      autoQuote,
      note,
      sortOrder,
      syncId,
      createdAt,
      updatedAt,
      quotePrice,
      quoteFetchedAt,
      quoteSourceId);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Holding &&
          other.id == this.id &&
          other.ledgerId == this.ledgerId &&
          other.accountId == this.accountId &&
          other.name == this.name &&
          other.symbol == this.symbol &&
          other.market == this.market &&
          other.assetClass == this.assetClass &&
          other.currency == this.currency &&
          other.quantity == this.quantity &&
          other.unitCost == this.unitCost &&
          other.unitPrice == this.unitPrice &&
          other.autoQuote == this.autoQuote &&
          other.note == this.note &&
          other.sortOrder == this.sortOrder &&
          other.syncId == this.syncId &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt &&
          other.quotePrice == this.quotePrice &&
          other.quoteFetchedAt == this.quoteFetchedAt &&
          other.quoteSourceId == this.quoteSourceId);
}

class HoldingsCompanion extends UpdateCompanion<Holding> {
  final Value<int> id;
  final Value<int> ledgerId;
  final Value<int> accountId;
  final Value<String> name;
  final Value<String?> symbol;
  final Value<String?> market;
  final Value<String> assetClass;
  final Value<String> currency;
  final Value<double> quantity;
  final Value<double> unitCost;
  final Value<double> unitPrice;
  final Value<bool> autoQuote;
  final Value<String?> note;
  final Value<int> sortOrder;
  final Value<String?> syncId;
  final Value<DateTime?> createdAt;
  final Value<DateTime?> updatedAt;
  final Value<double?> quotePrice;
  final Value<DateTime?> quoteFetchedAt;
  final Value<String?> quoteSourceId;
  const HoldingsCompanion({
    this.id = const Value.absent(),
    this.ledgerId = const Value.absent(),
    this.accountId = const Value.absent(),
    this.name = const Value.absent(),
    this.symbol = const Value.absent(),
    this.market = const Value.absent(),
    this.assetClass = const Value.absent(),
    this.currency = const Value.absent(),
    this.quantity = const Value.absent(),
    this.unitCost = const Value.absent(),
    this.unitPrice = const Value.absent(),
    this.autoQuote = const Value.absent(),
    this.note = const Value.absent(),
    this.sortOrder = const Value.absent(),
    this.syncId = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.quotePrice = const Value.absent(),
    this.quoteFetchedAt = const Value.absent(),
    this.quoteSourceId = const Value.absent(),
  });
  HoldingsCompanion.insert({
    this.id = const Value.absent(),
    this.ledgerId = const Value.absent(),
    required int accountId,
    required String name,
    this.symbol = const Value.absent(),
    this.market = const Value.absent(),
    this.assetClass = const Value.absent(),
    this.currency = const Value.absent(),
    this.quantity = const Value.absent(),
    this.unitCost = const Value.absent(),
    this.unitPrice = const Value.absent(),
    this.autoQuote = const Value.absent(),
    this.note = const Value.absent(),
    this.sortOrder = const Value.absent(),
    this.syncId = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.quotePrice = const Value.absent(),
    this.quoteFetchedAt = const Value.absent(),
    this.quoteSourceId = const Value.absent(),
  })  : accountId = Value(accountId),
        name = Value(name);
  static Insertable<Holding> custom({
    Expression<int>? id,
    Expression<int>? ledgerId,
    Expression<int>? accountId,
    Expression<String>? name,
    Expression<String>? symbol,
    Expression<String>? market,
    Expression<String>? assetClass,
    Expression<String>? currency,
    Expression<double>? quantity,
    Expression<double>? unitCost,
    Expression<double>? unitPrice,
    Expression<bool>? autoQuote,
    Expression<String>? note,
    Expression<int>? sortOrder,
    Expression<String>? syncId,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? updatedAt,
    Expression<double>? quotePrice,
    Expression<DateTime>? quoteFetchedAt,
    Expression<String>? quoteSourceId,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (ledgerId != null) 'ledger_id': ledgerId,
      if (accountId != null) 'account_id': accountId,
      if (name != null) 'name': name,
      if (symbol != null) 'symbol': symbol,
      if (market != null) 'market': market,
      if (assetClass != null) 'asset_class': assetClass,
      if (currency != null) 'currency': currency,
      if (quantity != null) 'quantity': quantity,
      if (unitCost != null) 'unit_cost': unitCost,
      if (unitPrice != null) 'unit_price': unitPrice,
      if (autoQuote != null) 'auto_quote': autoQuote,
      if (note != null) 'note': note,
      if (sortOrder != null) 'sort_order': sortOrder,
      if (syncId != null) 'sync_id': syncId,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (quotePrice != null) 'quote_price': quotePrice,
      if (quoteFetchedAt != null) 'quote_fetched_at': quoteFetchedAt,
      if (quoteSourceId != null) 'quote_source_id': quoteSourceId,
    });
  }

  HoldingsCompanion copyWith(
      {Value<int>? id,
      Value<int>? ledgerId,
      Value<int>? accountId,
      Value<String>? name,
      Value<String?>? symbol,
      Value<String?>? market,
      Value<String>? assetClass,
      Value<String>? currency,
      Value<double>? quantity,
      Value<double>? unitCost,
      Value<double>? unitPrice,
      Value<bool>? autoQuote,
      Value<String?>? note,
      Value<int>? sortOrder,
      Value<String?>? syncId,
      Value<DateTime?>? createdAt,
      Value<DateTime?>? updatedAt,
      Value<double?>? quotePrice,
      Value<DateTime?>? quoteFetchedAt,
      Value<String?>? quoteSourceId}) {
    return HoldingsCompanion(
      id: id ?? this.id,
      ledgerId: ledgerId ?? this.ledgerId,
      accountId: accountId ?? this.accountId,
      name: name ?? this.name,
      symbol: symbol ?? this.symbol,
      market: market ?? this.market,
      assetClass: assetClass ?? this.assetClass,
      currency: currency ?? this.currency,
      quantity: quantity ?? this.quantity,
      unitCost: unitCost ?? this.unitCost,
      unitPrice: unitPrice ?? this.unitPrice,
      autoQuote: autoQuote ?? this.autoQuote,
      note: note ?? this.note,
      sortOrder: sortOrder ?? this.sortOrder,
      syncId: syncId ?? this.syncId,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      quotePrice: quotePrice ?? this.quotePrice,
      quoteFetchedAt: quoteFetchedAt ?? this.quoteFetchedAt,
      quoteSourceId: quoteSourceId ?? this.quoteSourceId,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (ledgerId.present) {
      map['ledger_id'] = Variable<int>(ledgerId.value);
    }
    if (accountId.present) {
      map['account_id'] = Variable<int>(accountId.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (symbol.present) {
      map['symbol'] = Variable<String>(symbol.value);
    }
    if (market.present) {
      map['market'] = Variable<String>(market.value);
    }
    if (assetClass.present) {
      map['asset_class'] = Variable<String>(assetClass.value);
    }
    if (currency.present) {
      map['currency'] = Variable<String>(currency.value);
    }
    if (quantity.present) {
      map['quantity'] = Variable<double>(quantity.value);
    }
    if (unitCost.present) {
      map['unit_cost'] = Variable<double>(unitCost.value);
    }
    if (unitPrice.present) {
      map['unit_price'] = Variable<double>(unitPrice.value);
    }
    if (autoQuote.present) {
      map['auto_quote'] = Variable<bool>(autoQuote.value);
    }
    if (note.present) {
      map['note'] = Variable<String>(note.value);
    }
    if (sortOrder.present) {
      map['sort_order'] = Variable<int>(sortOrder.value);
    }
    if (syncId.present) {
      map['sync_id'] = Variable<String>(syncId.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (quotePrice.present) {
      map['quote_price'] = Variable<double>(quotePrice.value);
    }
    if (quoteFetchedAt.present) {
      map['quote_fetched_at'] = Variable<DateTime>(quoteFetchedAt.value);
    }
    if (quoteSourceId.present) {
      map['quote_source_id'] = Variable<String>(quoteSourceId.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('HoldingsCompanion(')
          ..write('id: $id, ')
          ..write('ledgerId: $ledgerId, ')
          ..write('accountId: $accountId, ')
          ..write('name: $name, ')
          ..write('symbol: $symbol, ')
          ..write('market: $market, ')
          ..write('assetClass: $assetClass, ')
          ..write('currency: $currency, ')
          ..write('quantity: $quantity, ')
          ..write('unitCost: $unitCost, ')
          ..write('unitPrice: $unitPrice, ')
          ..write('autoQuote: $autoQuote, ')
          ..write('note: $note, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('syncId: $syncId, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('quotePrice: $quotePrice, ')
          ..write('quoteFetchedAt: $quoteFetchedAt, ')
          ..write('quoteSourceId: $quoteSourceId')
          ..write(')'))
        .toString();
  }
}

class $CategoriesTable extends Categories
    with TableInfo<$CategoriesTable, Category> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CategoriesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
      'name', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _kindMeta = const VerificationMeta('kind');
  @override
  late final GeneratedColumn<String> kind = GeneratedColumn<String>(
      'kind', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _iconMeta = const VerificationMeta('icon');
  @override
  late final GeneratedColumn<String> icon = GeneratedColumn<String>(
      'icon', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _sortOrderMeta =
      const VerificationMeta('sortOrder');
  @override
  late final GeneratedColumn<int> sortOrder = GeneratedColumn<int>(
      'sort_order', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _parentIdMeta =
      const VerificationMeta('parentId');
  @override
  late final GeneratedColumn<int> parentId = GeneratedColumn<int>(
      'parent_id', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _levelMeta = const VerificationMeta('level');
  @override
  late final GeneratedColumn<int> level = GeneratedColumn<int>(
      'level', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(1));
  static const VerificationMeta _iconTypeMeta =
      const VerificationMeta('iconType');
  @override
  late final GeneratedColumn<String> iconType = GeneratedColumn<String>(
      'icon_type', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('material'));
  static const VerificationMeta _customIconPathMeta =
      const VerificationMeta('customIconPath');
  @override
  late final GeneratedColumn<String> customIconPath = GeneratedColumn<String>(
      'custom_icon_path', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _communityIconIdMeta =
      const VerificationMeta('communityIconId');
  @override
  late final GeneratedColumn<String> communityIconId = GeneratedColumn<String>(
      'community_icon_id', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _syncIdMeta = const VerificationMeta('syncId');
  @override
  late final GeneratedColumn<String> syncId = GeneratedColumn<String>(
      'sync_id', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _updatedAtMeta =
      const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
      'updated_at', aliasedName, true,
      type: DriftSqlType.dateTime, requiredDuringInsert: false);
  @override
  List<GeneratedColumn> get $columns => [
        id,
        name,
        kind,
        icon,
        sortOrder,
        parentId,
        level,
        iconType,
        customIconPath,
        communityIconId,
        syncId,
        updatedAt
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'categories';
  @override
  VerificationContext validateIntegrity(Insertable<Category> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('name')) {
      context.handle(
          _nameMeta, name.isAcceptableOrUnknown(data['name']!, _nameMeta));
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('kind')) {
      context.handle(
          _kindMeta, kind.isAcceptableOrUnknown(data['kind']!, _kindMeta));
    } else if (isInserting) {
      context.missing(_kindMeta);
    }
    if (data.containsKey('icon')) {
      context.handle(
          _iconMeta, icon.isAcceptableOrUnknown(data['icon']!, _iconMeta));
    }
    if (data.containsKey('sort_order')) {
      context.handle(_sortOrderMeta,
          sortOrder.isAcceptableOrUnknown(data['sort_order']!, _sortOrderMeta));
    }
    if (data.containsKey('parent_id')) {
      context.handle(_parentIdMeta,
          parentId.isAcceptableOrUnknown(data['parent_id']!, _parentIdMeta));
    }
    if (data.containsKey('level')) {
      context.handle(
          _levelMeta, level.isAcceptableOrUnknown(data['level']!, _levelMeta));
    }
    if (data.containsKey('icon_type')) {
      context.handle(_iconTypeMeta,
          iconType.isAcceptableOrUnknown(data['icon_type']!, _iconTypeMeta));
    }
    if (data.containsKey('custom_icon_path')) {
      context.handle(
          _customIconPathMeta,
          customIconPath.isAcceptableOrUnknown(
              data['custom_icon_path']!, _customIconPathMeta));
    }
    if (data.containsKey('community_icon_id')) {
      context.handle(
          _communityIconIdMeta,
          communityIconId.isAcceptableOrUnknown(
              data['community_icon_id']!, _communityIconIdMeta));
    }
    if (data.containsKey('sync_id')) {
      context.handle(_syncIdMeta,
          syncId.isAcceptableOrUnknown(data['sync_id']!, _syncIdMeta));
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta,
          updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Category map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Category(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      name: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}name'])!,
      kind: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}kind'])!,
      icon: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}icon']),
      sortOrder: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}sort_order'])!,
      parentId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}parent_id']),
      level: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}level'])!,
      iconType: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}icon_type'])!,
      customIconPath: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}custom_icon_path']),
      communityIconId: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}community_icon_id']),
      syncId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}sync_id']),
      updatedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}updated_at']),
    );
  }

  @override
  $CategoriesTable createAlias(String alias) {
    return $CategoriesTable(attachedDatabase, alias);
  }
}

class Category extends DataClass implements Insertable<Category> {
  final int id;
  final String name;
  final String kind;
  final String? icon;
  final int sortOrder;
  final int? parentId;
  final int level;
  final String iconType;
  final String? customIconPath;
  final String? communityIconId;
  final String? syncId;

  /// 审计 T1（v40）：见 Ledgers.updatedAt 注释。触发器
  /// trg_categories_touch_updated_at 自动维护。
  final DateTime? updatedAt;
  const Category(
      {required this.id,
      required this.name,
      required this.kind,
      this.icon,
      required this.sortOrder,
      this.parentId,
      required this.level,
      required this.iconType,
      this.customIconPath,
      this.communityIconId,
      this.syncId,
      this.updatedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['name'] = Variable<String>(name);
    map['kind'] = Variable<String>(kind);
    if (!nullToAbsent || icon != null) {
      map['icon'] = Variable<String>(icon);
    }
    map['sort_order'] = Variable<int>(sortOrder);
    if (!nullToAbsent || parentId != null) {
      map['parent_id'] = Variable<int>(parentId);
    }
    map['level'] = Variable<int>(level);
    map['icon_type'] = Variable<String>(iconType);
    if (!nullToAbsent || customIconPath != null) {
      map['custom_icon_path'] = Variable<String>(customIconPath);
    }
    if (!nullToAbsent || communityIconId != null) {
      map['community_icon_id'] = Variable<String>(communityIconId);
    }
    if (!nullToAbsent || syncId != null) {
      map['sync_id'] = Variable<String>(syncId);
    }
    if (!nullToAbsent || updatedAt != null) {
      map['updated_at'] = Variable<DateTime>(updatedAt);
    }
    return map;
  }

  CategoriesCompanion toCompanion(bool nullToAbsent) {
    return CategoriesCompanion(
      id: Value(id),
      name: Value(name),
      kind: Value(kind),
      icon: icon == null && nullToAbsent ? const Value.absent() : Value(icon),
      sortOrder: Value(sortOrder),
      parentId: parentId == null && nullToAbsent
          ? const Value.absent()
          : Value(parentId),
      level: Value(level),
      iconType: Value(iconType),
      customIconPath: customIconPath == null && nullToAbsent
          ? const Value.absent()
          : Value(customIconPath),
      communityIconId: communityIconId == null && nullToAbsent
          ? const Value.absent()
          : Value(communityIconId),
      syncId:
          syncId == null && nullToAbsent ? const Value.absent() : Value(syncId),
      updatedAt: updatedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(updatedAt),
    );
  }

  factory Category.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Category(
      id: serializer.fromJson<int>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      kind: serializer.fromJson<String>(json['kind']),
      icon: serializer.fromJson<String?>(json['icon']),
      sortOrder: serializer.fromJson<int>(json['sortOrder']),
      parentId: serializer.fromJson<int?>(json['parentId']),
      level: serializer.fromJson<int>(json['level']),
      iconType: serializer.fromJson<String>(json['iconType']),
      customIconPath: serializer.fromJson<String?>(json['customIconPath']),
      communityIconId: serializer.fromJson<String?>(json['communityIconId']),
      syncId: serializer.fromJson<String?>(json['syncId']),
      updatedAt: serializer.fromJson<DateTime?>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'name': serializer.toJson<String>(name),
      'kind': serializer.toJson<String>(kind),
      'icon': serializer.toJson<String?>(icon),
      'sortOrder': serializer.toJson<int>(sortOrder),
      'parentId': serializer.toJson<int?>(parentId),
      'level': serializer.toJson<int>(level),
      'iconType': serializer.toJson<String>(iconType),
      'customIconPath': serializer.toJson<String?>(customIconPath),
      'communityIconId': serializer.toJson<String?>(communityIconId),
      'syncId': serializer.toJson<String?>(syncId),
      'updatedAt': serializer.toJson<DateTime?>(updatedAt),
    };
  }

  Category copyWith(
          {int? id,
          String? name,
          String? kind,
          Value<String?> icon = const Value.absent(),
          int? sortOrder,
          Value<int?> parentId = const Value.absent(),
          int? level,
          String? iconType,
          Value<String?> customIconPath = const Value.absent(),
          Value<String?> communityIconId = const Value.absent(),
          Value<String?> syncId = const Value.absent(),
          Value<DateTime?> updatedAt = const Value.absent()}) =>
      Category(
        id: id ?? this.id,
        name: name ?? this.name,
        kind: kind ?? this.kind,
        icon: icon.present ? icon.value : this.icon,
        sortOrder: sortOrder ?? this.sortOrder,
        parentId: parentId.present ? parentId.value : this.parentId,
        level: level ?? this.level,
        iconType: iconType ?? this.iconType,
        customIconPath:
            customIconPath.present ? customIconPath.value : this.customIconPath,
        communityIconId: communityIconId.present
            ? communityIconId.value
            : this.communityIconId,
        syncId: syncId.present ? syncId.value : this.syncId,
        updatedAt: updatedAt.present ? updatedAt.value : this.updatedAt,
      );
  Category copyWithCompanion(CategoriesCompanion data) {
    return Category(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      kind: data.kind.present ? data.kind.value : this.kind,
      icon: data.icon.present ? data.icon.value : this.icon,
      sortOrder: data.sortOrder.present ? data.sortOrder.value : this.sortOrder,
      parentId: data.parentId.present ? data.parentId.value : this.parentId,
      level: data.level.present ? data.level.value : this.level,
      iconType: data.iconType.present ? data.iconType.value : this.iconType,
      customIconPath: data.customIconPath.present
          ? data.customIconPath.value
          : this.customIconPath,
      communityIconId: data.communityIconId.present
          ? data.communityIconId.value
          : this.communityIconId,
      syncId: data.syncId.present ? data.syncId.value : this.syncId,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Category(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('kind: $kind, ')
          ..write('icon: $icon, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('parentId: $parentId, ')
          ..write('level: $level, ')
          ..write('iconType: $iconType, ')
          ..write('customIconPath: $customIconPath, ')
          ..write('communityIconId: $communityIconId, ')
          ..write('syncId: $syncId, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, name, kind, icon, sortOrder, parentId,
      level, iconType, customIconPath, communityIconId, syncId, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Category &&
          other.id == this.id &&
          other.name == this.name &&
          other.kind == this.kind &&
          other.icon == this.icon &&
          other.sortOrder == this.sortOrder &&
          other.parentId == this.parentId &&
          other.level == this.level &&
          other.iconType == this.iconType &&
          other.customIconPath == this.customIconPath &&
          other.communityIconId == this.communityIconId &&
          other.syncId == this.syncId &&
          other.updatedAt == this.updatedAt);
}

class CategoriesCompanion extends UpdateCompanion<Category> {
  final Value<int> id;
  final Value<String> name;
  final Value<String> kind;
  final Value<String?> icon;
  final Value<int> sortOrder;
  final Value<int?> parentId;
  final Value<int> level;
  final Value<String> iconType;
  final Value<String?> customIconPath;
  final Value<String?> communityIconId;
  final Value<String?> syncId;
  final Value<DateTime?> updatedAt;
  const CategoriesCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.kind = const Value.absent(),
    this.icon = const Value.absent(),
    this.sortOrder = const Value.absent(),
    this.parentId = const Value.absent(),
    this.level = const Value.absent(),
    this.iconType = const Value.absent(),
    this.customIconPath = const Value.absent(),
    this.communityIconId = const Value.absent(),
    this.syncId = const Value.absent(),
    this.updatedAt = const Value.absent(),
  });
  CategoriesCompanion.insert({
    this.id = const Value.absent(),
    required String name,
    required String kind,
    this.icon = const Value.absent(),
    this.sortOrder = const Value.absent(),
    this.parentId = const Value.absent(),
    this.level = const Value.absent(),
    this.iconType = const Value.absent(),
    this.customIconPath = const Value.absent(),
    this.communityIconId = const Value.absent(),
    this.syncId = const Value.absent(),
    this.updatedAt = const Value.absent(),
  })  : name = Value(name),
        kind = Value(kind);
  static Insertable<Category> custom({
    Expression<int>? id,
    Expression<String>? name,
    Expression<String>? kind,
    Expression<String>? icon,
    Expression<int>? sortOrder,
    Expression<int>? parentId,
    Expression<int>? level,
    Expression<String>? iconType,
    Expression<String>? customIconPath,
    Expression<String>? communityIconId,
    Expression<String>? syncId,
    Expression<DateTime>? updatedAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (kind != null) 'kind': kind,
      if (icon != null) 'icon': icon,
      if (sortOrder != null) 'sort_order': sortOrder,
      if (parentId != null) 'parent_id': parentId,
      if (level != null) 'level': level,
      if (iconType != null) 'icon_type': iconType,
      if (customIconPath != null) 'custom_icon_path': customIconPath,
      if (communityIconId != null) 'community_icon_id': communityIconId,
      if (syncId != null) 'sync_id': syncId,
      if (updatedAt != null) 'updated_at': updatedAt,
    });
  }

  CategoriesCompanion copyWith(
      {Value<int>? id,
      Value<String>? name,
      Value<String>? kind,
      Value<String?>? icon,
      Value<int>? sortOrder,
      Value<int?>? parentId,
      Value<int>? level,
      Value<String>? iconType,
      Value<String?>? customIconPath,
      Value<String?>? communityIconId,
      Value<String?>? syncId,
      Value<DateTime?>? updatedAt}) {
    return CategoriesCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      kind: kind ?? this.kind,
      icon: icon ?? this.icon,
      sortOrder: sortOrder ?? this.sortOrder,
      parentId: parentId ?? this.parentId,
      level: level ?? this.level,
      iconType: iconType ?? this.iconType,
      customIconPath: customIconPath ?? this.customIconPath,
      communityIconId: communityIconId ?? this.communityIconId,
      syncId: syncId ?? this.syncId,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (kind.present) {
      map['kind'] = Variable<String>(kind.value);
    }
    if (icon.present) {
      map['icon'] = Variable<String>(icon.value);
    }
    if (sortOrder.present) {
      map['sort_order'] = Variable<int>(sortOrder.value);
    }
    if (parentId.present) {
      map['parent_id'] = Variable<int>(parentId.value);
    }
    if (level.present) {
      map['level'] = Variable<int>(level.value);
    }
    if (iconType.present) {
      map['icon_type'] = Variable<String>(iconType.value);
    }
    if (customIconPath.present) {
      map['custom_icon_path'] = Variable<String>(customIconPath.value);
    }
    if (communityIconId.present) {
      map['community_icon_id'] = Variable<String>(communityIconId.value);
    }
    if (syncId.present) {
      map['sync_id'] = Variable<String>(syncId.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CategoriesCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('kind: $kind, ')
          ..write('icon: $icon, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('parentId: $parentId, ')
          ..write('level: $level, ')
          ..write('iconType: $iconType, ')
          ..write('customIconPath: $customIconPath, ')
          ..write('communityIconId: $communityIconId, ')
          ..write('syncId: $syncId, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }
}

class $TransactionsTable extends Transactions
    with TableInfo<$TransactionsTable, Transaction> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $TransactionsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _ledgerIdMeta =
      const VerificationMeta('ledgerId');
  @override
  late final GeneratedColumn<int> ledgerId = GeneratedColumn<int>(
      'ledger_id', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _typeMeta = const VerificationMeta('type');
  @override
  late final GeneratedColumn<String> type = GeneratedColumn<String>(
      'type', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _amountMeta = const VerificationMeta('amount');
  @override
  late final GeneratedColumn<double> amount = GeneratedColumn<double>(
      'amount', aliasedName, false,
      type: DriftSqlType.double, requiredDuringInsert: true);
  static const VerificationMeta _categoryIdMeta =
      const VerificationMeta('categoryId');
  @override
  late final GeneratedColumn<int> categoryId = GeneratedColumn<int>(
      'category_id', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _accountIdMeta =
      const VerificationMeta('accountId');
  @override
  late final GeneratedColumn<int> accountId = GeneratedColumn<int>(
      'account_id', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _toAccountIdMeta =
      const VerificationMeta('toAccountId');
  @override
  late final GeneratedColumn<int> toAccountId = GeneratedColumn<int>(
      'to_account_id', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _happenedAtMeta =
      const VerificationMeta('happenedAt');
  @override
  late final GeneratedColumn<DateTime> happenedAt = GeneratedColumn<DateTime>(
      'happened_at', aliasedName, false,
      type: DriftSqlType.dateTime,
      requiredDuringInsert: false,
      defaultValue: currentDateAndTime);
  static const VerificationMeta _noteMeta = const VerificationMeta('note');
  @override
  late final GeneratedColumn<String> note = GeneratedColumn<String>(
      'note', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _recurringIdMeta =
      const VerificationMeta('recurringId');
  @override
  late final GeneratedColumn<int> recurringId = GeneratedColumn<int>(
      'recurring_id', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _syncIdMeta = const VerificationMeta('syncId');
  @override
  late final GeneratedColumn<String> syncId = GeneratedColumn<String>(
      'sync_id', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _createdByUserIdMeta =
      const VerificationMeta('createdByUserId');
  @override
  late final GeneratedColumn<String> createdByUserId = GeneratedColumn<String>(
      'created_by_user_id', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _lastEditedByUserIdMeta =
      const VerificationMeta('lastEditedByUserId');
  @override
  late final GeneratedColumn<String> lastEditedByUserId =
      GeneratedColumn<String>('last_edited_by_user_id', aliasedName, true,
          type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _excludeFromStatsMeta =
      const VerificationMeta('excludeFromStats');
  @override
  late final GeneratedColumn<bool> excludeFromStats = GeneratedColumn<bool>(
      'exclude_from_stats', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints: GeneratedColumn.constraintIsAlways(
          'CHECK ("exclude_from_stats" IN (0, 1))'),
      defaultValue: const Constant(false));
  static const VerificationMeta _excludeFromBudgetMeta =
      const VerificationMeta('excludeFromBudget');
  @override
  late final GeneratedColumn<bool> excludeFromBudget = GeneratedColumn<bool>(
      'exclude_from_budget', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints: GeneratedColumn.constraintIsAlways(
          'CHECK ("exclude_from_budget" IN (0, 1))'),
      defaultValue: const Constant(false));
  static const VerificationMeta _updatedAtMeta =
      const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
      'updated_at', aliasedName, true,
      type: DriftSqlType.dateTime, requiredDuringInsert: false);
  static const VerificationMeta _currencyCodeMeta =
      const VerificationMeta('currencyCode');
  @override
  late final GeneratedColumn<String> currencyCode = GeneratedColumn<String>(
      'currency_code', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _nativeAmountMeta =
      const VerificationMeta('nativeAmount');
  @override
  late final GeneratedColumn<double> nativeAmount = GeneratedColumn<double>(
      'native_amount', aliasedName, true,
      type: DriftSqlType.double, requiredDuringInsert: false);
  static const VerificationMeta _originalAmountMeta =
      const VerificationMeta('originalAmount');
  @override
  late final GeneratedColumn<double> originalAmount = GeneratedColumn<double>(
      'original_amount', aliasedName, true,
      type: DriftSqlType.double, requiredDuringInsert: false);
  static const VerificationMeta _customValuesJsonMeta =
      const VerificationMeta('customValuesJson');
  @override
  late final GeneratedColumn<String> customValuesJson = GeneratedColumn<String>(
      'custom_values_json', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  @override
  List<GeneratedColumn> get $columns => [
        id,
        ledgerId,
        type,
        amount,
        categoryId,
        accountId,
        toAccountId,
        happenedAt,
        note,
        recurringId,
        syncId,
        createdByUserId,
        lastEditedByUserId,
        excludeFromStats,
        excludeFromBudget,
        updatedAt,
        currencyCode,
        nativeAmount,
        originalAmount,
        customValuesJson
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'transactions';
  @override
  VerificationContext validateIntegrity(Insertable<Transaction> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('ledger_id')) {
      context.handle(_ledgerIdMeta,
          ledgerId.isAcceptableOrUnknown(data['ledger_id']!, _ledgerIdMeta));
    } else if (isInserting) {
      context.missing(_ledgerIdMeta);
    }
    if (data.containsKey('type')) {
      context.handle(
          _typeMeta, type.isAcceptableOrUnknown(data['type']!, _typeMeta));
    } else if (isInserting) {
      context.missing(_typeMeta);
    }
    if (data.containsKey('amount')) {
      context.handle(_amountMeta,
          amount.isAcceptableOrUnknown(data['amount']!, _amountMeta));
    } else if (isInserting) {
      context.missing(_amountMeta);
    }
    if (data.containsKey('category_id')) {
      context.handle(
          _categoryIdMeta,
          categoryId.isAcceptableOrUnknown(
              data['category_id']!, _categoryIdMeta));
    }
    if (data.containsKey('account_id')) {
      context.handle(_accountIdMeta,
          accountId.isAcceptableOrUnknown(data['account_id']!, _accountIdMeta));
    }
    if (data.containsKey('to_account_id')) {
      context.handle(
          _toAccountIdMeta,
          toAccountId.isAcceptableOrUnknown(
              data['to_account_id']!, _toAccountIdMeta));
    }
    if (data.containsKey('happened_at')) {
      context.handle(
          _happenedAtMeta,
          happenedAt.isAcceptableOrUnknown(
              data['happened_at']!, _happenedAtMeta));
    }
    if (data.containsKey('note')) {
      context.handle(
          _noteMeta, note.isAcceptableOrUnknown(data['note']!, _noteMeta));
    }
    if (data.containsKey('recurring_id')) {
      context.handle(
          _recurringIdMeta,
          recurringId.isAcceptableOrUnknown(
              data['recurring_id']!, _recurringIdMeta));
    }
    if (data.containsKey('sync_id')) {
      context.handle(_syncIdMeta,
          syncId.isAcceptableOrUnknown(data['sync_id']!, _syncIdMeta));
    }
    if (data.containsKey('created_by_user_id')) {
      context.handle(
          _createdByUserIdMeta,
          createdByUserId.isAcceptableOrUnknown(
              data['created_by_user_id']!, _createdByUserIdMeta));
    }
    if (data.containsKey('last_edited_by_user_id')) {
      context.handle(
          _lastEditedByUserIdMeta,
          lastEditedByUserId.isAcceptableOrUnknown(
              data['last_edited_by_user_id']!, _lastEditedByUserIdMeta));
    }
    if (data.containsKey('exclude_from_stats')) {
      context.handle(
          _excludeFromStatsMeta,
          excludeFromStats.isAcceptableOrUnknown(
              data['exclude_from_stats']!, _excludeFromStatsMeta));
    }
    if (data.containsKey('exclude_from_budget')) {
      context.handle(
          _excludeFromBudgetMeta,
          excludeFromBudget.isAcceptableOrUnknown(
              data['exclude_from_budget']!, _excludeFromBudgetMeta));
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta,
          updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
    }
    if (data.containsKey('currency_code')) {
      context.handle(
          _currencyCodeMeta,
          currencyCode.isAcceptableOrUnknown(
              data['currency_code']!, _currencyCodeMeta));
    }
    if (data.containsKey('native_amount')) {
      context.handle(
          _nativeAmountMeta,
          nativeAmount.isAcceptableOrUnknown(
              data['native_amount']!, _nativeAmountMeta));
    }
    if (data.containsKey('original_amount')) {
      context.handle(
          _originalAmountMeta,
          originalAmount.isAcceptableOrUnknown(
              data['original_amount']!, _originalAmountMeta));
    }
    if (data.containsKey('custom_values_json')) {
      context.handle(
          _customValuesJsonMeta,
          customValuesJson.isAcceptableOrUnknown(
              data['custom_values_json']!, _customValuesJsonMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Transaction map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Transaction(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      ledgerId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}ledger_id'])!,
      type: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}type'])!,
      amount: attachedDatabase.typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}amount'])!,
      categoryId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}category_id']),
      accountId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}account_id']),
      toAccountId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}to_account_id']),
      happenedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}happened_at'])!,
      note: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}note']),
      recurringId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}recurring_id']),
      syncId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}sync_id']),
      createdByUserId: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}created_by_user_id']),
      lastEditedByUserId: attachedDatabase.typeMapping.read(DriftSqlType.string,
          data['${effectivePrefix}last_edited_by_user_id']),
      excludeFromStats: attachedDatabase.typeMapping.read(
          DriftSqlType.bool, data['${effectivePrefix}exclude_from_stats'])!,
      excludeFromBudget: attachedDatabase.typeMapping.read(
          DriftSqlType.bool, data['${effectivePrefix}exclude_from_budget'])!,
      updatedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}updated_at']),
      currencyCode: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}currency_code']),
      nativeAmount: attachedDatabase.typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}native_amount']),
      originalAmount: attachedDatabase.typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}original_amount']),
      customValuesJson: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}custom_values_json']),
    );
  }

  @override
  $TransactionsTable createAlias(String alias) {
    return $TransactionsTable(attachedDatabase, alias);
  }
}

class Transaction extends DataClass implements Insertable<Transaction> {
  final int id;
  final int ledgerId;
  final String type;
  final double amount;
  final int? categoryId;
  final int? accountId;
  final int? toAccountId;
  final DateTime happenedAt;
  final String? note;
  final int? recurringId;
  final String? syncId;
  final String? createdByUserId;
  final String? lastEditedByUserId;

  /// 不计入收支:true 时从收支统计/图表/月年汇总剔除,但仍计入账户余额、净资产、
  /// 账单列表(.docs/transaction-flags/01 §二 D1)。
  final bool excludeFromStats;

  /// 不计入预算:true 时从预算用量剔除。与 excludeFromStats 完全独立(D2)。
  final bool excludeFromBudget;

  /// 审计 T1（v40）：见 Ledgers.updatedAt 注释。触发器
  /// trg_transactions_touch_updated_at 自动维护。
  final DateTime? updatedAt;

  /// v30 交易级多币种(.docs/multi-currency-ledger):交易币种(ISO 大写)。
  /// 有账户 → 恒等于账户 currency(账户内不混币);无账户 → 用户所选(L12,
  /// 默认账本本位币)。显式存让交易自包含(同步/统计不必每次 join 账户)。
  final String? currencyCode;

  /// v30:折算到账本本位币的金额快照(按记账时汇率,保存即定,不随汇率重算)。
  /// 单币种/未折算 == amount(隐含汇率 1.0)。账本维度统计读本列(?? amount),
  /// 账户维度(余额等)仍读 amount。
  final double? nativeAmount;

  /// v45:原始金额(记账时用户手动填写的来源/票面金额,如发票原价)。
  /// NULL = 用户未填写,语义等价于「默认金额 = 记账金额 amount」。
  /// 刻意不回填存量行 —— 物理 NULL 才能区分「未填写」与「手填了相同值」,
  /// 且历史明细的统计口径零变化。读取/统计统一走
  /// `COALESCE(original_amount, amount)`,单一口径避免散落兜底。
  final double? originalAmount;

  /// v46: 自定义字段值,{fieldSyncId: value} 的 JSON 对象。
  /// - 键是 [CustomFieldDefinitions.syncId](而非本地 int id),天然适配
  ///   共享账本 —— Editor 写入 Owner 定义的字段值无需 override 表。
  /// - 值为 JSON 原生类型:金额存 number、日期存 ISO-8601 字符串、文本存原文。
  /// - NULL = 该笔无任何自定义字段值(未填写/全部清空),存量行保持 NULL,
  ///   导出时**不写该键**,与 v45 original_amount 同款防漂移范式。
  /// - 仅在编辑表单读写,不参与列表/统计 SQL,所以不必可查询、无须索引。
  final String? customValuesJson;
  const Transaction(
      {required this.id,
      required this.ledgerId,
      required this.type,
      required this.amount,
      this.categoryId,
      this.accountId,
      this.toAccountId,
      required this.happenedAt,
      this.note,
      this.recurringId,
      this.syncId,
      this.createdByUserId,
      this.lastEditedByUserId,
      required this.excludeFromStats,
      required this.excludeFromBudget,
      this.updatedAt,
      this.currencyCode,
      this.nativeAmount,
      this.originalAmount,
      this.customValuesJson});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['ledger_id'] = Variable<int>(ledgerId);
    map['type'] = Variable<String>(type);
    map['amount'] = Variable<double>(amount);
    if (!nullToAbsent || categoryId != null) {
      map['category_id'] = Variable<int>(categoryId);
    }
    if (!nullToAbsent || accountId != null) {
      map['account_id'] = Variable<int>(accountId);
    }
    if (!nullToAbsent || toAccountId != null) {
      map['to_account_id'] = Variable<int>(toAccountId);
    }
    map['happened_at'] = Variable<DateTime>(happenedAt);
    if (!nullToAbsent || note != null) {
      map['note'] = Variable<String>(note);
    }
    if (!nullToAbsent || recurringId != null) {
      map['recurring_id'] = Variable<int>(recurringId);
    }
    if (!nullToAbsent || syncId != null) {
      map['sync_id'] = Variable<String>(syncId);
    }
    if (!nullToAbsent || createdByUserId != null) {
      map['created_by_user_id'] = Variable<String>(createdByUserId);
    }
    if (!nullToAbsent || lastEditedByUserId != null) {
      map['last_edited_by_user_id'] = Variable<String>(lastEditedByUserId);
    }
    map['exclude_from_stats'] = Variable<bool>(excludeFromStats);
    map['exclude_from_budget'] = Variable<bool>(excludeFromBudget);
    if (!nullToAbsent || updatedAt != null) {
      map['updated_at'] = Variable<DateTime>(updatedAt);
    }
    if (!nullToAbsent || currencyCode != null) {
      map['currency_code'] = Variable<String>(currencyCode);
    }
    if (!nullToAbsent || nativeAmount != null) {
      map['native_amount'] = Variable<double>(nativeAmount);
    }
    if (!nullToAbsent || originalAmount != null) {
      map['original_amount'] = Variable<double>(originalAmount);
    }
    if (!nullToAbsent || customValuesJson != null) {
      map['custom_values_json'] = Variable<String>(customValuesJson);
    }
    return map;
  }

  TransactionsCompanion toCompanion(bool nullToAbsent) {
    return TransactionsCompanion(
      id: Value(id),
      ledgerId: Value(ledgerId),
      type: Value(type),
      amount: Value(amount),
      categoryId: categoryId == null && nullToAbsent
          ? const Value.absent()
          : Value(categoryId),
      accountId: accountId == null && nullToAbsent
          ? const Value.absent()
          : Value(accountId),
      toAccountId: toAccountId == null && nullToAbsent
          ? const Value.absent()
          : Value(toAccountId),
      happenedAt: Value(happenedAt),
      note: note == null && nullToAbsent ? const Value.absent() : Value(note),
      recurringId: recurringId == null && nullToAbsent
          ? const Value.absent()
          : Value(recurringId),
      syncId:
          syncId == null && nullToAbsent ? const Value.absent() : Value(syncId),
      createdByUserId: createdByUserId == null && nullToAbsent
          ? const Value.absent()
          : Value(createdByUserId),
      lastEditedByUserId: lastEditedByUserId == null && nullToAbsent
          ? const Value.absent()
          : Value(lastEditedByUserId),
      excludeFromStats: Value(excludeFromStats),
      excludeFromBudget: Value(excludeFromBudget),
      updatedAt: updatedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(updatedAt),
      currencyCode: currencyCode == null && nullToAbsent
          ? const Value.absent()
          : Value(currencyCode),
      nativeAmount: nativeAmount == null && nullToAbsent
          ? const Value.absent()
          : Value(nativeAmount),
      originalAmount: originalAmount == null && nullToAbsent
          ? const Value.absent()
          : Value(originalAmount),
      customValuesJson: customValuesJson == null && nullToAbsent
          ? const Value.absent()
          : Value(customValuesJson),
    );
  }

  factory Transaction.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Transaction(
      id: serializer.fromJson<int>(json['id']),
      ledgerId: serializer.fromJson<int>(json['ledgerId']),
      type: serializer.fromJson<String>(json['type']),
      amount: serializer.fromJson<double>(json['amount']),
      categoryId: serializer.fromJson<int?>(json['categoryId']),
      accountId: serializer.fromJson<int?>(json['accountId']),
      toAccountId: serializer.fromJson<int?>(json['toAccountId']),
      happenedAt: serializer.fromJson<DateTime>(json['happenedAt']),
      note: serializer.fromJson<String?>(json['note']),
      recurringId: serializer.fromJson<int?>(json['recurringId']),
      syncId: serializer.fromJson<String?>(json['syncId']),
      createdByUserId: serializer.fromJson<String?>(json['createdByUserId']),
      lastEditedByUserId:
          serializer.fromJson<String?>(json['lastEditedByUserId']),
      excludeFromStats: serializer.fromJson<bool>(json['excludeFromStats']),
      excludeFromBudget: serializer.fromJson<bool>(json['excludeFromBudget']),
      updatedAt: serializer.fromJson<DateTime?>(json['updatedAt']),
      currencyCode: serializer.fromJson<String?>(json['currencyCode']),
      nativeAmount: serializer.fromJson<double?>(json['nativeAmount']),
      originalAmount: serializer.fromJson<double?>(json['originalAmount']),
      customValuesJson: serializer.fromJson<String?>(json['customValuesJson']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'ledgerId': serializer.toJson<int>(ledgerId),
      'type': serializer.toJson<String>(type),
      'amount': serializer.toJson<double>(amount),
      'categoryId': serializer.toJson<int?>(categoryId),
      'accountId': serializer.toJson<int?>(accountId),
      'toAccountId': serializer.toJson<int?>(toAccountId),
      'happenedAt': serializer.toJson<DateTime>(happenedAt),
      'note': serializer.toJson<String?>(note),
      'recurringId': serializer.toJson<int?>(recurringId),
      'syncId': serializer.toJson<String?>(syncId),
      'createdByUserId': serializer.toJson<String?>(createdByUserId),
      'lastEditedByUserId': serializer.toJson<String?>(lastEditedByUserId),
      'excludeFromStats': serializer.toJson<bool>(excludeFromStats),
      'excludeFromBudget': serializer.toJson<bool>(excludeFromBudget),
      'updatedAt': serializer.toJson<DateTime?>(updatedAt),
      'currencyCode': serializer.toJson<String?>(currencyCode),
      'nativeAmount': serializer.toJson<double?>(nativeAmount),
      'originalAmount': serializer.toJson<double?>(originalAmount),
      'customValuesJson': serializer.toJson<String?>(customValuesJson),
    };
  }

  Transaction copyWith(
          {int? id,
          int? ledgerId,
          String? type,
          double? amount,
          Value<int?> categoryId = const Value.absent(),
          Value<int?> accountId = const Value.absent(),
          Value<int?> toAccountId = const Value.absent(),
          DateTime? happenedAt,
          Value<String?> note = const Value.absent(),
          Value<int?> recurringId = const Value.absent(),
          Value<String?> syncId = const Value.absent(),
          Value<String?> createdByUserId = const Value.absent(),
          Value<String?> lastEditedByUserId = const Value.absent(),
          bool? excludeFromStats,
          bool? excludeFromBudget,
          Value<DateTime?> updatedAt = const Value.absent(),
          Value<String?> currencyCode = const Value.absent(),
          Value<double?> nativeAmount = const Value.absent(),
          Value<double?> originalAmount = const Value.absent(),
          Value<String?> customValuesJson = const Value.absent()}) =>
      Transaction(
        id: id ?? this.id,
        ledgerId: ledgerId ?? this.ledgerId,
        type: type ?? this.type,
        amount: amount ?? this.amount,
        categoryId: categoryId.present ? categoryId.value : this.categoryId,
        accountId: accountId.present ? accountId.value : this.accountId,
        toAccountId: toAccountId.present ? toAccountId.value : this.toAccountId,
        happenedAt: happenedAt ?? this.happenedAt,
        note: note.present ? note.value : this.note,
        recurringId: recurringId.present ? recurringId.value : this.recurringId,
        syncId: syncId.present ? syncId.value : this.syncId,
        createdByUserId: createdByUserId.present
            ? createdByUserId.value
            : this.createdByUserId,
        lastEditedByUserId: lastEditedByUserId.present
            ? lastEditedByUserId.value
            : this.lastEditedByUserId,
        excludeFromStats: excludeFromStats ?? this.excludeFromStats,
        excludeFromBudget: excludeFromBudget ?? this.excludeFromBudget,
        updatedAt: updatedAt.present ? updatedAt.value : this.updatedAt,
        currencyCode:
            currencyCode.present ? currencyCode.value : this.currencyCode,
        nativeAmount:
            nativeAmount.present ? nativeAmount.value : this.nativeAmount,
        originalAmount:
            originalAmount.present ? originalAmount.value : this.originalAmount,
        customValuesJson: customValuesJson.present
            ? customValuesJson.value
            : this.customValuesJson,
      );
  Transaction copyWithCompanion(TransactionsCompanion data) {
    return Transaction(
      id: data.id.present ? data.id.value : this.id,
      ledgerId: data.ledgerId.present ? data.ledgerId.value : this.ledgerId,
      type: data.type.present ? data.type.value : this.type,
      amount: data.amount.present ? data.amount.value : this.amount,
      categoryId:
          data.categoryId.present ? data.categoryId.value : this.categoryId,
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      toAccountId:
          data.toAccountId.present ? data.toAccountId.value : this.toAccountId,
      happenedAt:
          data.happenedAt.present ? data.happenedAt.value : this.happenedAt,
      note: data.note.present ? data.note.value : this.note,
      recurringId:
          data.recurringId.present ? data.recurringId.value : this.recurringId,
      syncId: data.syncId.present ? data.syncId.value : this.syncId,
      createdByUserId: data.createdByUserId.present
          ? data.createdByUserId.value
          : this.createdByUserId,
      lastEditedByUserId: data.lastEditedByUserId.present
          ? data.lastEditedByUserId.value
          : this.lastEditedByUserId,
      excludeFromStats: data.excludeFromStats.present
          ? data.excludeFromStats.value
          : this.excludeFromStats,
      excludeFromBudget: data.excludeFromBudget.present
          ? data.excludeFromBudget.value
          : this.excludeFromBudget,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      currencyCode: data.currencyCode.present
          ? data.currencyCode.value
          : this.currencyCode,
      nativeAmount: data.nativeAmount.present
          ? data.nativeAmount.value
          : this.nativeAmount,
      originalAmount: data.originalAmount.present
          ? data.originalAmount.value
          : this.originalAmount,
      customValuesJson: data.customValuesJson.present
          ? data.customValuesJson.value
          : this.customValuesJson,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Transaction(')
          ..write('id: $id, ')
          ..write('ledgerId: $ledgerId, ')
          ..write('type: $type, ')
          ..write('amount: $amount, ')
          ..write('categoryId: $categoryId, ')
          ..write('accountId: $accountId, ')
          ..write('toAccountId: $toAccountId, ')
          ..write('happenedAt: $happenedAt, ')
          ..write('note: $note, ')
          ..write('recurringId: $recurringId, ')
          ..write('syncId: $syncId, ')
          ..write('createdByUserId: $createdByUserId, ')
          ..write('lastEditedByUserId: $lastEditedByUserId, ')
          ..write('excludeFromStats: $excludeFromStats, ')
          ..write('excludeFromBudget: $excludeFromBudget, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('currencyCode: $currencyCode, ')
          ..write('nativeAmount: $nativeAmount, ')
          ..write('originalAmount: $originalAmount, ')
          ..write('customValuesJson: $customValuesJson')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      id,
      ledgerId,
      type,
      amount,
      categoryId,
      accountId,
      toAccountId,
      happenedAt,
      note,
      recurringId,
      syncId,
      createdByUserId,
      lastEditedByUserId,
      excludeFromStats,
      excludeFromBudget,
      updatedAt,
      currencyCode,
      nativeAmount,
      originalAmount,
      customValuesJson);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Transaction &&
          other.id == this.id &&
          other.ledgerId == this.ledgerId &&
          other.type == this.type &&
          other.amount == this.amount &&
          other.categoryId == this.categoryId &&
          other.accountId == this.accountId &&
          other.toAccountId == this.toAccountId &&
          other.happenedAt == this.happenedAt &&
          other.note == this.note &&
          other.recurringId == this.recurringId &&
          other.syncId == this.syncId &&
          other.createdByUserId == this.createdByUserId &&
          other.lastEditedByUserId == this.lastEditedByUserId &&
          other.excludeFromStats == this.excludeFromStats &&
          other.excludeFromBudget == this.excludeFromBudget &&
          other.updatedAt == this.updatedAt &&
          other.currencyCode == this.currencyCode &&
          other.nativeAmount == this.nativeAmount &&
          other.originalAmount == this.originalAmount &&
          other.customValuesJson == this.customValuesJson);
}

class TransactionsCompanion extends UpdateCompanion<Transaction> {
  final Value<int> id;
  final Value<int> ledgerId;
  final Value<String> type;
  final Value<double> amount;
  final Value<int?> categoryId;
  final Value<int?> accountId;
  final Value<int?> toAccountId;
  final Value<DateTime> happenedAt;
  final Value<String?> note;
  final Value<int?> recurringId;
  final Value<String?> syncId;
  final Value<String?> createdByUserId;
  final Value<String?> lastEditedByUserId;
  final Value<bool> excludeFromStats;
  final Value<bool> excludeFromBudget;
  final Value<DateTime?> updatedAt;
  final Value<String?> currencyCode;
  final Value<double?> nativeAmount;
  final Value<double?> originalAmount;
  final Value<String?> customValuesJson;
  const TransactionsCompanion({
    this.id = const Value.absent(),
    this.ledgerId = const Value.absent(),
    this.type = const Value.absent(),
    this.amount = const Value.absent(),
    this.categoryId = const Value.absent(),
    this.accountId = const Value.absent(),
    this.toAccountId = const Value.absent(),
    this.happenedAt = const Value.absent(),
    this.note = const Value.absent(),
    this.recurringId = const Value.absent(),
    this.syncId = const Value.absent(),
    this.createdByUserId = const Value.absent(),
    this.lastEditedByUserId = const Value.absent(),
    this.excludeFromStats = const Value.absent(),
    this.excludeFromBudget = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.currencyCode = const Value.absent(),
    this.nativeAmount = const Value.absent(),
    this.originalAmount = const Value.absent(),
    this.customValuesJson = const Value.absent(),
  });
  TransactionsCompanion.insert({
    this.id = const Value.absent(),
    required int ledgerId,
    required String type,
    required double amount,
    this.categoryId = const Value.absent(),
    this.accountId = const Value.absent(),
    this.toAccountId = const Value.absent(),
    this.happenedAt = const Value.absent(),
    this.note = const Value.absent(),
    this.recurringId = const Value.absent(),
    this.syncId = const Value.absent(),
    this.createdByUserId = const Value.absent(),
    this.lastEditedByUserId = const Value.absent(),
    this.excludeFromStats = const Value.absent(),
    this.excludeFromBudget = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.currencyCode = const Value.absent(),
    this.nativeAmount = const Value.absent(),
    this.originalAmount = const Value.absent(),
    this.customValuesJson = const Value.absent(),
  })  : ledgerId = Value(ledgerId),
        type = Value(type),
        amount = Value(amount);
  static Insertable<Transaction> custom({
    Expression<int>? id,
    Expression<int>? ledgerId,
    Expression<String>? type,
    Expression<double>? amount,
    Expression<int>? categoryId,
    Expression<int>? accountId,
    Expression<int>? toAccountId,
    Expression<DateTime>? happenedAt,
    Expression<String>? note,
    Expression<int>? recurringId,
    Expression<String>? syncId,
    Expression<String>? createdByUserId,
    Expression<String>? lastEditedByUserId,
    Expression<bool>? excludeFromStats,
    Expression<bool>? excludeFromBudget,
    Expression<DateTime>? updatedAt,
    Expression<String>? currencyCode,
    Expression<double>? nativeAmount,
    Expression<double>? originalAmount,
    Expression<String>? customValuesJson,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (ledgerId != null) 'ledger_id': ledgerId,
      if (type != null) 'type': type,
      if (amount != null) 'amount': amount,
      if (categoryId != null) 'category_id': categoryId,
      if (accountId != null) 'account_id': accountId,
      if (toAccountId != null) 'to_account_id': toAccountId,
      if (happenedAt != null) 'happened_at': happenedAt,
      if (note != null) 'note': note,
      if (recurringId != null) 'recurring_id': recurringId,
      if (syncId != null) 'sync_id': syncId,
      if (createdByUserId != null) 'created_by_user_id': createdByUserId,
      if (lastEditedByUserId != null)
        'last_edited_by_user_id': lastEditedByUserId,
      if (excludeFromStats != null) 'exclude_from_stats': excludeFromStats,
      if (excludeFromBudget != null) 'exclude_from_budget': excludeFromBudget,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (currencyCode != null) 'currency_code': currencyCode,
      if (nativeAmount != null) 'native_amount': nativeAmount,
      if (originalAmount != null) 'original_amount': originalAmount,
      if (customValuesJson != null) 'custom_values_json': customValuesJson,
    });
  }

  TransactionsCompanion copyWith(
      {Value<int>? id,
      Value<int>? ledgerId,
      Value<String>? type,
      Value<double>? amount,
      Value<int?>? categoryId,
      Value<int?>? accountId,
      Value<int?>? toAccountId,
      Value<DateTime>? happenedAt,
      Value<String?>? note,
      Value<int?>? recurringId,
      Value<String?>? syncId,
      Value<String?>? createdByUserId,
      Value<String?>? lastEditedByUserId,
      Value<bool>? excludeFromStats,
      Value<bool>? excludeFromBudget,
      Value<DateTime?>? updatedAt,
      Value<String?>? currencyCode,
      Value<double?>? nativeAmount,
      Value<double?>? originalAmount,
      Value<String?>? customValuesJson}) {
    return TransactionsCompanion(
      id: id ?? this.id,
      ledgerId: ledgerId ?? this.ledgerId,
      type: type ?? this.type,
      amount: amount ?? this.amount,
      categoryId: categoryId ?? this.categoryId,
      accountId: accountId ?? this.accountId,
      toAccountId: toAccountId ?? this.toAccountId,
      happenedAt: happenedAt ?? this.happenedAt,
      note: note ?? this.note,
      recurringId: recurringId ?? this.recurringId,
      syncId: syncId ?? this.syncId,
      createdByUserId: createdByUserId ?? this.createdByUserId,
      lastEditedByUserId: lastEditedByUserId ?? this.lastEditedByUserId,
      excludeFromStats: excludeFromStats ?? this.excludeFromStats,
      excludeFromBudget: excludeFromBudget ?? this.excludeFromBudget,
      updatedAt: updatedAt ?? this.updatedAt,
      currencyCode: currencyCode ?? this.currencyCode,
      nativeAmount: nativeAmount ?? this.nativeAmount,
      originalAmount: originalAmount ?? this.originalAmount,
      customValuesJson: customValuesJson ?? this.customValuesJson,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (ledgerId.present) {
      map['ledger_id'] = Variable<int>(ledgerId.value);
    }
    if (type.present) {
      map['type'] = Variable<String>(type.value);
    }
    if (amount.present) {
      map['amount'] = Variable<double>(amount.value);
    }
    if (categoryId.present) {
      map['category_id'] = Variable<int>(categoryId.value);
    }
    if (accountId.present) {
      map['account_id'] = Variable<int>(accountId.value);
    }
    if (toAccountId.present) {
      map['to_account_id'] = Variable<int>(toAccountId.value);
    }
    if (happenedAt.present) {
      map['happened_at'] = Variable<DateTime>(happenedAt.value);
    }
    if (note.present) {
      map['note'] = Variable<String>(note.value);
    }
    if (recurringId.present) {
      map['recurring_id'] = Variable<int>(recurringId.value);
    }
    if (syncId.present) {
      map['sync_id'] = Variable<String>(syncId.value);
    }
    if (createdByUserId.present) {
      map['created_by_user_id'] = Variable<String>(createdByUserId.value);
    }
    if (lastEditedByUserId.present) {
      map['last_edited_by_user_id'] =
          Variable<String>(lastEditedByUserId.value);
    }
    if (excludeFromStats.present) {
      map['exclude_from_stats'] = Variable<bool>(excludeFromStats.value);
    }
    if (excludeFromBudget.present) {
      map['exclude_from_budget'] = Variable<bool>(excludeFromBudget.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (currencyCode.present) {
      map['currency_code'] = Variable<String>(currencyCode.value);
    }
    if (nativeAmount.present) {
      map['native_amount'] = Variable<double>(nativeAmount.value);
    }
    if (originalAmount.present) {
      map['original_amount'] = Variable<double>(originalAmount.value);
    }
    if (customValuesJson.present) {
      map['custom_values_json'] = Variable<String>(customValuesJson.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('TransactionsCompanion(')
          ..write('id: $id, ')
          ..write('ledgerId: $ledgerId, ')
          ..write('type: $type, ')
          ..write('amount: $amount, ')
          ..write('categoryId: $categoryId, ')
          ..write('accountId: $accountId, ')
          ..write('toAccountId: $toAccountId, ')
          ..write('happenedAt: $happenedAt, ')
          ..write('note: $note, ')
          ..write('recurringId: $recurringId, ')
          ..write('syncId: $syncId, ')
          ..write('createdByUserId: $createdByUserId, ')
          ..write('lastEditedByUserId: $lastEditedByUserId, ')
          ..write('excludeFromStats: $excludeFromStats, ')
          ..write('excludeFromBudget: $excludeFromBudget, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('currencyCode: $currencyCode, ')
          ..write('nativeAmount: $nativeAmount, ')
          ..write('originalAmount: $originalAmount, ')
          ..write('customValuesJson: $customValuesJson')
          ..write(')'))
        .toString();
  }
}

class $RecurringTransactionsTable extends RecurringTransactions
    with TableInfo<$RecurringTransactionsTable, RecurringTransaction> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $RecurringTransactionsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _ledgerIdMeta =
      const VerificationMeta('ledgerId');
  @override
  late final GeneratedColumn<int> ledgerId = GeneratedColumn<int>(
      'ledger_id', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _syncIdMeta = const VerificationMeta('syncId');
  @override
  late final GeneratedColumn<String> syncId = GeneratedColumn<String>(
      'sync_id', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _typeMeta = const VerificationMeta('type');
  @override
  late final GeneratedColumn<String> type = GeneratedColumn<String>(
      'type', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _amountMeta = const VerificationMeta('amount');
  @override
  late final GeneratedColumn<double> amount = GeneratedColumn<double>(
      'amount', aliasedName, false,
      type: DriftSqlType.double, requiredDuringInsert: true);
  static const VerificationMeta _categoryIdMeta =
      const VerificationMeta('categoryId');
  @override
  late final GeneratedColumn<int> categoryId = GeneratedColumn<int>(
      'category_id', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _accountIdMeta =
      const VerificationMeta('accountId');
  @override
  late final GeneratedColumn<int> accountId = GeneratedColumn<int>(
      'account_id', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _toAccountIdMeta =
      const VerificationMeta('toAccountId');
  @override
  late final GeneratedColumn<int> toAccountId = GeneratedColumn<int>(
      'to_account_id', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _noteMeta = const VerificationMeta('note');
  @override
  late final GeneratedColumn<String> note = GeneratedColumn<String>(
      'note', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _frequencyMeta =
      const VerificationMeta('frequency');
  @override
  late final GeneratedColumn<String> frequency = GeneratedColumn<String>(
      'frequency', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _intervalMeta =
      const VerificationMeta('interval');
  @override
  late final GeneratedColumn<int> interval = GeneratedColumn<int>(
      'interval', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(1));
  static const VerificationMeta _dayOfMonthMeta =
      const VerificationMeta('dayOfMonth');
  @override
  late final GeneratedColumn<int> dayOfMonth = GeneratedColumn<int>(
      'day_of_month', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _dayOfWeekMeta =
      const VerificationMeta('dayOfWeek');
  @override
  late final GeneratedColumn<int> dayOfWeek = GeneratedColumn<int>(
      'day_of_week', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _monthOfYearMeta =
      const VerificationMeta('monthOfYear');
  @override
  late final GeneratedColumn<int> monthOfYear = GeneratedColumn<int>(
      'month_of_year', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _startDateMeta =
      const VerificationMeta('startDate');
  @override
  late final GeneratedColumn<DateTime> startDate = GeneratedColumn<DateTime>(
      'start_date', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  static const VerificationMeta _endDateMeta =
      const VerificationMeta('endDate');
  @override
  late final GeneratedColumn<DateTime> endDate = GeneratedColumn<DateTime>(
      'end_date', aliasedName, true,
      type: DriftSqlType.dateTime, requiredDuringInsert: false);
  static const VerificationMeta _lastGeneratedDateMeta =
      const VerificationMeta('lastGeneratedDate');
  @override
  late final GeneratedColumn<DateTime> lastGeneratedDate =
      GeneratedColumn<DateTime>('last_generated_date', aliasedName, true,
          type: DriftSqlType.dateTime, requiredDuringInsert: false);
  static const VerificationMeta _enabledMeta =
      const VerificationMeta('enabled');
  @override
  late final GeneratedColumn<bool> enabled = GeneratedColumn<bool>(
      'enabled', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("enabled" IN (0, 1))'),
      defaultValue: const Constant(true));
  static const VerificationMeta _currencyCodeMeta =
      const VerificationMeta('currencyCode');
  @override
  late final GeneratedColumn<String> currencyCode = GeneratedColumn<String>(
      'currency_code', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _templateFieldValuesMeta =
      const VerificationMeta('templateFieldValues');
  @override
  late final GeneratedColumn<String> templateFieldValues =
      GeneratedColumn<String>('template_field_values', aliasedName, true,
          type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
      'created_at', aliasedName, false,
      type: DriftSqlType.dateTime,
      requiredDuringInsert: false,
      defaultValue: currentDateAndTime);
  static const VerificationMeta _updatedAtMeta =
      const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
      'updated_at', aliasedName, false,
      type: DriftSqlType.dateTime,
      requiredDuringInsert: false,
      defaultValue: currentDateAndTime);
  @override
  List<GeneratedColumn> get $columns => [
        id,
        ledgerId,
        syncId,
        type,
        amount,
        categoryId,
        accountId,
        toAccountId,
        note,
        frequency,
        interval,
        dayOfMonth,
        dayOfWeek,
        monthOfYear,
        startDate,
        endDate,
        lastGeneratedDate,
        enabled,
        currencyCode,
        templateFieldValues,
        createdAt,
        updatedAt
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'recurring_transactions';
  @override
  VerificationContext validateIntegrity(
      Insertable<RecurringTransaction> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('ledger_id')) {
      context.handle(_ledgerIdMeta,
          ledgerId.isAcceptableOrUnknown(data['ledger_id']!, _ledgerIdMeta));
    } else if (isInserting) {
      context.missing(_ledgerIdMeta);
    }
    if (data.containsKey('sync_id')) {
      context.handle(_syncIdMeta,
          syncId.isAcceptableOrUnknown(data['sync_id']!, _syncIdMeta));
    }
    if (data.containsKey('type')) {
      context.handle(
          _typeMeta, type.isAcceptableOrUnknown(data['type']!, _typeMeta));
    } else if (isInserting) {
      context.missing(_typeMeta);
    }
    if (data.containsKey('amount')) {
      context.handle(_amountMeta,
          amount.isAcceptableOrUnknown(data['amount']!, _amountMeta));
    } else if (isInserting) {
      context.missing(_amountMeta);
    }
    if (data.containsKey('category_id')) {
      context.handle(
          _categoryIdMeta,
          categoryId.isAcceptableOrUnknown(
              data['category_id']!, _categoryIdMeta));
    }
    if (data.containsKey('account_id')) {
      context.handle(_accountIdMeta,
          accountId.isAcceptableOrUnknown(data['account_id']!, _accountIdMeta));
    }
    if (data.containsKey('to_account_id')) {
      context.handle(
          _toAccountIdMeta,
          toAccountId.isAcceptableOrUnknown(
              data['to_account_id']!, _toAccountIdMeta));
    }
    if (data.containsKey('note')) {
      context.handle(
          _noteMeta, note.isAcceptableOrUnknown(data['note']!, _noteMeta));
    }
    if (data.containsKey('frequency')) {
      context.handle(_frequencyMeta,
          frequency.isAcceptableOrUnknown(data['frequency']!, _frequencyMeta));
    } else if (isInserting) {
      context.missing(_frequencyMeta);
    }
    if (data.containsKey('interval')) {
      context.handle(_intervalMeta,
          interval.isAcceptableOrUnknown(data['interval']!, _intervalMeta));
    }
    if (data.containsKey('day_of_month')) {
      context.handle(
          _dayOfMonthMeta,
          dayOfMonth.isAcceptableOrUnknown(
              data['day_of_month']!, _dayOfMonthMeta));
    }
    if (data.containsKey('day_of_week')) {
      context.handle(
          _dayOfWeekMeta,
          dayOfWeek.isAcceptableOrUnknown(
              data['day_of_week']!, _dayOfWeekMeta));
    }
    if (data.containsKey('month_of_year')) {
      context.handle(
          _monthOfYearMeta,
          monthOfYear.isAcceptableOrUnknown(
              data['month_of_year']!, _monthOfYearMeta));
    }
    if (data.containsKey('start_date')) {
      context.handle(_startDateMeta,
          startDate.isAcceptableOrUnknown(data['start_date']!, _startDateMeta));
    } else if (isInserting) {
      context.missing(_startDateMeta);
    }
    if (data.containsKey('end_date')) {
      context.handle(_endDateMeta,
          endDate.isAcceptableOrUnknown(data['end_date']!, _endDateMeta));
    }
    if (data.containsKey('last_generated_date')) {
      context.handle(
          _lastGeneratedDateMeta,
          lastGeneratedDate.isAcceptableOrUnknown(
              data['last_generated_date']!, _lastGeneratedDateMeta));
    }
    if (data.containsKey('enabled')) {
      context.handle(_enabledMeta,
          enabled.isAcceptableOrUnknown(data['enabled']!, _enabledMeta));
    }
    if (data.containsKey('currency_code')) {
      context.handle(
          _currencyCodeMeta,
          currencyCode.isAcceptableOrUnknown(
              data['currency_code']!, _currencyCodeMeta));
    }
    if (data.containsKey('template_field_values')) {
      context.handle(
          _templateFieldValuesMeta,
          templateFieldValues.isAcceptableOrUnknown(
              data['template_field_values']!, _templateFieldValuesMeta));
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta,
          updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  RecurringTransaction map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return RecurringTransaction(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      ledgerId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}ledger_id'])!,
      syncId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}sync_id']),
      type: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}type'])!,
      amount: attachedDatabase.typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}amount'])!,
      categoryId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}category_id']),
      accountId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}account_id']),
      toAccountId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}to_account_id']),
      note: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}note']),
      frequency: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}frequency'])!,
      interval: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}interval'])!,
      dayOfMonth: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}day_of_month']),
      dayOfWeek: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}day_of_week']),
      monthOfYear: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}month_of_year']),
      startDate: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}start_date'])!,
      endDate: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}end_date']),
      lastGeneratedDate: attachedDatabase.typeMapping.read(
          DriftSqlType.dateTime, data['${effectivePrefix}last_generated_date']),
      enabled: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}enabled'])!,
      currencyCode: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}currency_code']),
      templateFieldValues: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}template_field_values']),
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}created_at'])!,
      updatedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}updated_at'])!,
    );
  }

  @override
  $RecurringTransactionsTable createAlias(String alias) {
    return $RecurringTransactionsTable(attachedDatabase, alias);
  }
}

class RecurringTransaction extends DataClass
    implements Insertable<RecurringTransaction> {
  final int id;
  final int ledgerId;

  /// 跨设备同步 syncId。v33 新增,migration 给老行补随机 hex;
  /// 语义与 budgets.syncId(v22)/accounts.syncId 一致:快照与 Cloud
  /// 链路都按此做跨设备实体锚定(cloud_recurring_sync PRD)。
  final String? syncId;
  final String type;
  final double amount;
  final int? categoryId;
  final int? accountId;
  final int? toAccountId;
  final String? note;
  final String frequency;
  final int interval;
  final int? dayOfMonth;
  final int? dayOfWeek;
  final int? monthOfYear;
  final DateTime startDate;
  final DateTime? endDate;
  final DateTime? lastGeneratedDate;
  final bool enabled;

  /// v42 周期账单币种(移植 BeeCount #444):模板币种(ISO 大写)。
  /// NULL = 账本本位币(存量语义);挂了账户时生成仍以账户币种为准(账户内不混币)。
  /// 汇率不锁在模板上 —— 每次生成按当日有效汇率折算 nativeAmount。
  final String? currencyCode;

  /// v47: 周期账单模板级自定义字段值,{fieldSyncId: value} 的 JSON 对象。
  /// - 生成实例时整包注入 `transactions.custom_values_json`(实例侧再改不影响
  ///   模板,下一次生成仍按模板值)。
  /// - 编解码必须走 CustomFieldValueCodec(见 models/custom_field_values.dart,
  ///   键序/数值表示统一),与交易值同款。
  /// - NULL = 模板未配置任何字段值;存量行保持 NULL,导出**不写该键**(v45/v46
  ///   同款防漂移范式:回填 `{}` 会让"旧快照无此键"与"显式空对象"指纹不一致)。
  /// - 仅编辑表单与生成器读写,无须索引。
  final String? templateFieldValues;
  final DateTime createdAt;
  final DateTime updatedAt;
  const RecurringTransaction(
      {required this.id,
      required this.ledgerId,
      this.syncId,
      required this.type,
      required this.amount,
      this.categoryId,
      this.accountId,
      this.toAccountId,
      this.note,
      required this.frequency,
      required this.interval,
      this.dayOfMonth,
      this.dayOfWeek,
      this.monthOfYear,
      required this.startDate,
      this.endDate,
      this.lastGeneratedDate,
      required this.enabled,
      this.currencyCode,
      this.templateFieldValues,
      required this.createdAt,
      required this.updatedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['ledger_id'] = Variable<int>(ledgerId);
    if (!nullToAbsent || syncId != null) {
      map['sync_id'] = Variable<String>(syncId);
    }
    map['type'] = Variable<String>(type);
    map['amount'] = Variable<double>(amount);
    if (!nullToAbsent || categoryId != null) {
      map['category_id'] = Variable<int>(categoryId);
    }
    if (!nullToAbsent || accountId != null) {
      map['account_id'] = Variable<int>(accountId);
    }
    if (!nullToAbsent || toAccountId != null) {
      map['to_account_id'] = Variable<int>(toAccountId);
    }
    if (!nullToAbsent || note != null) {
      map['note'] = Variable<String>(note);
    }
    map['frequency'] = Variable<String>(frequency);
    map['interval'] = Variable<int>(interval);
    if (!nullToAbsent || dayOfMonth != null) {
      map['day_of_month'] = Variable<int>(dayOfMonth);
    }
    if (!nullToAbsent || dayOfWeek != null) {
      map['day_of_week'] = Variable<int>(dayOfWeek);
    }
    if (!nullToAbsent || monthOfYear != null) {
      map['month_of_year'] = Variable<int>(monthOfYear);
    }
    map['start_date'] = Variable<DateTime>(startDate);
    if (!nullToAbsent || endDate != null) {
      map['end_date'] = Variable<DateTime>(endDate);
    }
    if (!nullToAbsent || lastGeneratedDate != null) {
      map['last_generated_date'] = Variable<DateTime>(lastGeneratedDate);
    }
    map['enabled'] = Variable<bool>(enabled);
    if (!nullToAbsent || currencyCode != null) {
      map['currency_code'] = Variable<String>(currencyCode);
    }
    if (!nullToAbsent || templateFieldValues != null) {
      map['template_field_values'] = Variable<String>(templateFieldValues);
    }
    map['created_at'] = Variable<DateTime>(createdAt);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    return map;
  }

  RecurringTransactionsCompanion toCompanion(bool nullToAbsent) {
    return RecurringTransactionsCompanion(
      id: Value(id),
      ledgerId: Value(ledgerId),
      syncId:
          syncId == null && nullToAbsent ? const Value.absent() : Value(syncId),
      type: Value(type),
      amount: Value(amount),
      categoryId: categoryId == null && nullToAbsent
          ? const Value.absent()
          : Value(categoryId),
      accountId: accountId == null && nullToAbsent
          ? const Value.absent()
          : Value(accountId),
      toAccountId: toAccountId == null && nullToAbsent
          ? const Value.absent()
          : Value(toAccountId),
      note: note == null && nullToAbsent ? const Value.absent() : Value(note),
      frequency: Value(frequency),
      interval: Value(interval),
      dayOfMonth: dayOfMonth == null && nullToAbsent
          ? const Value.absent()
          : Value(dayOfMonth),
      dayOfWeek: dayOfWeek == null && nullToAbsent
          ? const Value.absent()
          : Value(dayOfWeek),
      monthOfYear: monthOfYear == null && nullToAbsent
          ? const Value.absent()
          : Value(monthOfYear),
      startDate: Value(startDate),
      endDate: endDate == null && nullToAbsent
          ? const Value.absent()
          : Value(endDate),
      lastGeneratedDate: lastGeneratedDate == null && nullToAbsent
          ? const Value.absent()
          : Value(lastGeneratedDate),
      enabled: Value(enabled),
      currencyCode: currencyCode == null && nullToAbsent
          ? const Value.absent()
          : Value(currencyCode),
      templateFieldValues: templateFieldValues == null && nullToAbsent
          ? const Value.absent()
          : Value(templateFieldValues),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory RecurringTransaction.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return RecurringTransaction(
      id: serializer.fromJson<int>(json['id']),
      ledgerId: serializer.fromJson<int>(json['ledgerId']),
      syncId: serializer.fromJson<String?>(json['syncId']),
      type: serializer.fromJson<String>(json['type']),
      amount: serializer.fromJson<double>(json['amount']),
      categoryId: serializer.fromJson<int?>(json['categoryId']),
      accountId: serializer.fromJson<int?>(json['accountId']),
      toAccountId: serializer.fromJson<int?>(json['toAccountId']),
      note: serializer.fromJson<String?>(json['note']),
      frequency: serializer.fromJson<String>(json['frequency']),
      interval: serializer.fromJson<int>(json['interval']),
      dayOfMonth: serializer.fromJson<int?>(json['dayOfMonth']),
      dayOfWeek: serializer.fromJson<int?>(json['dayOfWeek']),
      monthOfYear: serializer.fromJson<int?>(json['monthOfYear']),
      startDate: serializer.fromJson<DateTime>(json['startDate']),
      endDate: serializer.fromJson<DateTime?>(json['endDate']),
      lastGeneratedDate:
          serializer.fromJson<DateTime?>(json['lastGeneratedDate']),
      enabled: serializer.fromJson<bool>(json['enabled']),
      currencyCode: serializer.fromJson<String?>(json['currencyCode']),
      templateFieldValues:
          serializer.fromJson<String?>(json['templateFieldValues']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'ledgerId': serializer.toJson<int>(ledgerId),
      'syncId': serializer.toJson<String?>(syncId),
      'type': serializer.toJson<String>(type),
      'amount': serializer.toJson<double>(amount),
      'categoryId': serializer.toJson<int?>(categoryId),
      'accountId': serializer.toJson<int?>(accountId),
      'toAccountId': serializer.toJson<int?>(toAccountId),
      'note': serializer.toJson<String?>(note),
      'frequency': serializer.toJson<String>(frequency),
      'interval': serializer.toJson<int>(interval),
      'dayOfMonth': serializer.toJson<int?>(dayOfMonth),
      'dayOfWeek': serializer.toJson<int?>(dayOfWeek),
      'monthOfYear': serializer.toJson<int?>(monthOfYear),
      'startDate': serializer.toJson<DateTime>(startDate),
      'endDate': serializer.toJson<DateTime?>(endDate),
      'lastGeneratedDate': serializer.toJson<DateTime?>(lastGeneratedDate),
      'enabled': serializer.toJson<bool>(enabled),
      'currencyCode': serializer.toJson<String?>(currencyCode),
      'templateFieldValues': serializer.toJson<String?>(templateFieldValues),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
    };
  }

  RecurringTransaction copyWith(
          {int? id,
          int? ledgerId,
          Value<String?> syncId = const Value.absent(),
          String? type,
          double? amount,
          Value<int?> categoryId = const Value.absent(),
          Value<int?> accountId = const Value.absent(),
          Value<int?> toAccountId = const Value.absent(),
          Value<String?> note = const Value.absent(),
          String? frequency,
          int? interval,
          Value<int?> dayOfMonth = const Value.absent(),
          Value<int?> dayOfWeek = const Value.absent(),
          Value<int?> monthOfYear = const Value.absent(),
          DateTime? startDate,
          Value<DateTime?> endDate = const Value.absent(),
          Value<DateTime?> lastGeneratedDate = const Value.absent(),
          bool? enabled,
          Value<String?> currencyCode = const Value.absent(),
          Value<String?> templateFieldValues = const Value.absent(),
          DateTime? createdAt,
          DateTime? updatedAt}) =>
      RecurringTransaction(
        id: id ?? this.id,
        ledgerId: ledgerId ?? this.ledgerId,
        syncId: syncId.present ? syncId.value : this.syncId,
        type: type ?? this.type,
        amount: amount ?? this.amount,
        categoryId: categoryId.present ? categoryId.value : this.categoryId,
        accountId: accountId.present ? accountId.value : this.accountId,
        toAccountId: toAccountId.present ? toAccountId.value : this.toAccountId,
        note: note.present ? note.value : this.note,
        frequency: frequency ?? this.frequency,
        interval: interval ?? this.interval,
        dayOfMonth: dayOfMonth.present ? dayOfMonth.value : this.dayOfMonth,
        dayOfWeek: dayOfWeek.present ? dayOfWeek.value : this.dayOfWeek,
        monthOfYear: monthOfYear.present ? monthOfYear.value : this.monthOfYear,
        startDate: startDate ?? this.startDate,
        endDate: endDate.present ? endDate.value : this.endDate,
        lastGeneratedDate: lastGeneratedDate.present
            ? lastGeneratedDate.value
            : this.lastGeneratedDate,
        enabled: enabled ?? this.enabled,
        currencyCode:
            currencyCode.present ? currencyCode.value : this.currencyCode,
        templateFieldValues: templateFieldValues.present
            ? templateFieldValues.value
            : this.templateFieldValues,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );
  RecurringTransaction copyWithCompanion(RecurringTransactionsCompanion data) {
    return RecurringTransaction(
      id: data.id.present ? data.id.value : this.id,
      ledgerId: data.ledgerId.present ? data.ledgerId.value : this.ledgerId,
      syncId: data.syncId.present ? data.syncId.value : this.syncId,
      type: data.type.present ? data.type.value : this.type,
      amount: data.amount.present ? data.amount.value : this.amount,
      categoryId:
          data.categoryId.present ? data.categoryId.value : this.categoryId,
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      toAccountId:
          data.toAccountId.present ? data.toAccountId.value : this.toAccountId,
      note: data.note.present ? data.note.value : this.note,
      frequency: data.frequency.present ? data.frequency.value : this.frequency,
      interval: data.interval.present ? data.interval.value : this.interval,
      dayOfMonth:
          data.dayOfMonth.present ? data.dayOfMonth.value : this.dayOfMonth,
      dayOfWeek: data.dayOfWeek.present ? data.dayOfWeek.value : this.dayOfWeek,
      monthOfYear:
          data.monthOfYear.present ? data.monthOfYear.value : this.monthOfYear,
      startDate: data.startDate.present ? data.startDate.value : this.startDate,
      endDate: data.endDate.present ? data.endDate.value : this.endDate,
      lastGeneratedDate: data.lastGeneratedDate.present
          ? data.lastGeneratedDate.value
          : this.lastGeneratedDate,
      enabled: data.enabled.present ? data.enabled.value : this.enabled,
      currencyCode: data.currencyCode.present
          ? data.currencyCode.value
          : this.currencyCode,
      templateFieldValues: data.templateFieldValues.present
          ? data.templateFieldValues.value
          : this.templateFieldValues,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('RecurringTransaction(')
          ..write('id: $id, ')
          ..write('ledgerId: $ledgerId, ')
          ..write('syncId: $syncId, ')
          ..write('type: $type, ')
          ..write('amount: $amount, ')
          ..write('categoryId: $categoryId, ')
          ..write('accountId: $accountId, ')
          ..write('toAccountId: $toAccountId, ')
          ..write('note: $note, ')
          ..write('frequency: $frequency, ')
          ..write('interval: $interval, ')
          ..write('dayOfMonth: $dayOfMonth, ')
          ..write('dayOfWeek: $dayOfWeek, ')
          ..write('monthOfYear: $monthOfYear, ')
          ..write('startDate: $startDate, ')
          ..write('endDate: $endDate, ')
          ..write('lastGeneratedDate: $lastGeneratedDate, ')
          ..write('enabled: $enabled, ')
          ..write('currencyCode: $currencyCode, ')
          ..write('templateFieldValues: $templateFieldValues, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hashAll([
        id,
        ledgerId,
        syncId,
        type,
        amount,
        categoryId,
        accountId,
        toAccountId,
        note,
        frequency,
        interval,
        dayOfMonth,
        dayOfWeek,
        monthOfYear,
        startDate,
        endDate,
        lastGeneratedDate,
        enabled,
        currencyCode,
        templateFieldValues,
        createdAt,
        updatedAt
      ]);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is RecurringTransaction &&
          other.id == this.id &&
          other.ledgerId == this.ledgerId &&
          other.syncId == this.syncId &&
          other.type == this.type &&
          other.amount == this.amount &&
          other.categoryId == this.categoryId &&
          other.accountId == this.accountId &&
          other.toAccountId == this.toAccountId &&
          other.note == this.note &&
          other.frequency == this.frequency &&
          other.interval == this.interval &&
          other.dayOfMonth == this.dayOfMonth &&
          other.dayOfWeek == this.dayOfWeek &&
          other.monthOfYear == this.monthOfYear &&
          other.startDate == this.startDate &&
          other.endDate == this.endDate &&
          other.lastGeneratedDate == this.lastGeneratedDate &&
          other.enabled == this.enabled &&
          other.currencyCode == this.currencyCode &&
          other.templateFieldValues == this.templateFieldValues &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class RecurringTransactionsCompanion
    extends UpdateCompanion<RecurringTransaction> {
  final Value<int> id;
  final Value<int> ledgerId;
  final Value<String?> syncId;
  final Value<String> type;
  final Value<double> amount;
  final Value<int?> categoryId;
  final Value<int?> accountId;
  final Value<int?> toAccountId;
  final Value<String?> note;
  final Value<String> frequency;
  final Value<int> interval;
  final Value<int?> dayOfMonth;
  final Value<int?> dayOfWeek;
  final Value<int?> monthOfYear;
  final Value<DateTime> startDate;
  final Value<DateTime?> endDate;
  final Value<DateTime?> lastGeneratedDate;
  final Value<bool> enabled;
  final Value<String?> currencyCode;
  final Value<String?> templateFieldValues;
  final Value<DateTime> createdAt;
  final Value<DateTime> updatedAt;
  const RecurringTransactionsCompanion({
    this.id = const Value.absent(),
    this.ledgerId = const Value.absent(),
    this.syncId = const Value.absent(),
    this.type = const Value.absent(),
    this.amount = const Value.absent(),
    this.categoryId = const Value.absent(),
    this.accountId = const Value.absent(),
    this.toAccountId = const Value.absent(),
    this.note = const Value.absent(),
    this.frequency = const Value.absent(),
    this.interval = const Value.absent(),
    this.dayOfMonth = const Value.absent(),
    this.dayOfWeek = const Value.absent(),
    this.monthOfYear = const Value.absent(),
    this.startDate = const Value.absent(),
    this.endDate = const Value.absent(),
    this.lastGeneratedDate = const Value.absent(),
    this.enabled = const Value.absent(),
    this.currencyCode = const Value.absent(),
    this.templateFieldValues = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
  });
  RecurringTransactionsCompanion.insert({
    this.id = const Value.absent(),
    required int ledgerId,
    this.syncId = const Value.absent(),
    required String type,
    required double amount,
    this.categoryId = const Value.absent(),
    this.accountId = const Value.absent(),
    this.toAccountId = const Value.absent(),
    this.note = const Value.absent(),
    required String frequency,
    this.interval = const Value.absent(),
    this.dayOfMonth = const Value.absent(),
    this.dayOfWeek = const Value.absent(),
    this.monthOfYear = const Value.absent(),
    required DateTime startDate,
    this.endDate = const Value.absent(),
    this.lastGeneratedDate = const Value.absent(),
    this.enabled = const Value.absent(),
    this.currencyCode = const Value.absent(),
    this.templateFieldValues = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
  })  : ledgerId = Value(ledgerId),
        type = Value(type),
        amount = Value(amount),
        frequency = Value(frequency),
        startDate = Value(startDate);
  static Insertable<RecurringTransaction> custom({
    Expression<int>? id,
    Expression<int>? ledgerId,
    Expression<String>? syncId,
    Expression<String>? type,
    Expression<double>? amount,
    Expression<int>? categoryId,
    Expression<int>? accountId,
    Expression<int>? toAccountId,
    Expression<String>? note,
    Expression<String>? frequency,
    Expression<int>? interval,
    Expression<int>? dayOfMonth,
    Expression<int>? dayOfWeek,
    Expression<int>? monthOfYear,
    Expression<DateTime>? startDate,
    Expression<DateTime>? endDate,
    Expression<DateTime>? lastGeneratedDate,
    Expression<bool>? enabled,
    Expression<String>? currencyCode,
    Expression<String>? templateFieldValues,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? updatedAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (ledgerId != null) 'ledger_id': ledgerId,
      if (syncId != null) 'sync_id': syncId,
      if (type != null) 'type': type,
      if (amount != null) 'amount': amount,
      if (categoryId != null) 'category_id': categoryId,
      if (accountId != null) 'account_id': accountId,
      if (toAccountId != null) 'to_account_id': toAccountId,
      if (note != null) 'note': note,
      if (frequency != null) 'frequency': frequency,
      if (interval != null) 'interval': interval,
      if (dayOfMonth != null) 'day_of_month': dayOfMonth,
      if (dayOfWeek != null) 'day_of_week': dayOfWeek,
      if (monthOfYear != null) 'month_of_year': monthOfYear,
      if (startDate != null) 'start_date': startDate,
      if (endDate != null) 'end_date': endDate,
      if (lastGeneratedDate != null) 'last_generated_date': lastGeneratedDate,
      if (enabled != null) 'enabled': enabled,
      if (currencyCode != null) 'currency_code': currencyCode,
      if (templateFieldValues != null)
        'template_field_values': templateFieldValues,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
    });
  }

  RecurringTransactionsCompanion copyWith(
      {Value<int>? id,
      Value<int>? ledgerId,
      Value<String?>? syncId,
      Value<String>? type,
      Value<double>? amount,
      Value<int?>? categoryId,
      Value<int?>? accountId,
      Value<int?>? toAccountId,
      Value<String?>? note,
      Value<String>? frequency,
      Value<int>? interval,
      Value<int?>? dayOfMonth,
      Value<int?>? dayOfWeek,
      Value<int?>? monthOfYear,
      Value<DateTime>? startDate,
      Value<DateTime?>? endDate,
      Value<DateTime?>? lastGeneratedDate,
      Value<bool>? enabled,
      Value<String?>? currencyCode,
      Value<String?>? templateFieldValues,
      Value<DateTime>? createdAt,
      Value<DateTime>? updatedAt}) {
    return RecurringTransactionsCompanion(
      id: id ?? this.id,
      ledgerId: ledgerId ?? this.ledgerId,
      syncId: syncId ?? this.syncId,
      type: type ?? this.type,
      amount: amount ?? this.amount,
      categoryId: categoryId ?? this.categoryId,
      accountId: accountId ?? this.accountId,
      toAccountId: toAccountId ?? this.toAccountId,
      note: note ?? this.note,
      frequency: frequency ?? this.frequency,
      interval: interval ?? this.interval,
      dayOfMonth: dayOfMonth ?? this.dayOfMonth,
      dayOfWeek: dayOfWeek ?? this.dayOfWeek,
      monthOfYear: monthOfYear ?? this.monthOfYear,
      startDate: startDate ?? this.startDate,
      endDate: endDate ?? this.endDate,
      lastGeneratedDate: lastGeneratedDate ?? this.lastGeneratedDate,
      enabled: enabled ?? this.enabled,
      currencyCode: currencyCode ?? this.currencyCode,
      templateFieldValues: templateFieldValues ?? this.templateFieldValues,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (ledgerId.present) {
      map['ledger_id'] = Variable<int>(ledgerId.value);
    }
    if (syncId.present) {
      map['sync_id'] = Variable<String>(syncId.value);
    }
    if (type.present) {
      map['type'] = Variable<String>(type.value);
    }
    if (amount.present) {
      map['amount'] = Variable<double>(amount.value);
    }
    if (categoryId.present) {
      map['category_id'] = Variable<int>(categoryId.value);
    }
    if (accountId.present) {
      map['account_id'] = Variable<int>(accountId.value);
    }
    if (toAccountId.present) {
      map['to_account_id'] = Variable<int>(toAccountId.value);
    }
    if (note.present) {
      map['note'] = Variable<String>(note.value);
    }
    if (frequency.present) {
      map['frequency'] = Variable<String>(frequency.value);
    }
    if (interval.present) {
      map['interval'] = Variable<int>(interval.value);
    }
    if (dayOfMonth.present) {
      map['day_of_month'] = Variable<int>(dayOfMonth.value);
    }
    if (dayOfWeek.present) {
      map['day_of_week'] = Variable<int>(dayOfWeek.value);
    }
    if (monthOfYear.present) {
      map['month_of_year'] = Variable<int>(monthOfYear.value);
    }
    if (startDate.present) {
      map['start_date'] = Variable<DateTime>(startDate.value);
    }
    if (endDate.present) {
      map['end_date'] = Variable<DateTime>(endDate.value);
    }
    if (lastGeneratedDate.present) {
      map['last_generated_date'] = Variable<DateTime>(lastGeneratedDate.value);
    }
    if (enabled.present) {
      map['enabled'] = Variable<bool>(enabled.value);
    }
    if (currencyCode.present) {
      map['currency_code'] = Variable<String>(currencyCode.value);
    }
    if (templateFieldValues.present) {
      map['template_field_values'] =
          Variable<String>(templateFieldValues.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('RecurringTransactionsCompanion(')
          ..write('id: $id, ')
          ..write('ledgerId: $ledgerId, ')
          ..write('syncId: $syncId, ')
          ..write('type: $type, ')
          ..write('amount: $amount, ')
          ..write('categoryId: $categoryId, ')
          ..write('accountId: $accountId, ')
          ..write('toAccountId: $toAccountId, ')
          ..write('note: $note, ')
          ..write('frequency: $frequency, ')
          ..write('interval: $interval, ')
          ..write('dayOfMonth: $dayOfMonth, ')
          ..write('dayOfWeek: $dayOfWeek, ')
          ..write('monthOfYear: $monthOfYear, ')
          ..write('startDate: $startDate, ')
          ..write('endDate: $endDate, ')
          ..write('lastGeneratedDate: $lastGeneratedDate, ')
          ..write('enabled: $enabled, ')
          ..write('currencyCode: $currencyCode, ')
          ..write('templateFieldValues: $templateFieldValues, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }
}

class $ConversationsTable extends Conversations
    with TableInfo<$ConversationsTable, Conversation> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ConversationsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _ledgerIdMeta =
      const VerificationMeta('ledgerId');
  @override
  late final GeneratedColumn<int> ledgerId = GeneratedColumn<int>(
      'ledger_id', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
      'title', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('AI对话'));
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
      'created_at', aliasedName, false,
      type: DriftSqlType.dateTime,
      requiredDuringInsert: false,
      defaultValue: currentDateAndTime);
  static const VerificationMeta _updatedAtMeta =
      const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
      'updated_at', aliasedName, false,
      type: DriftSqlType.dateTime,
      requiredDuringInsert: false,
      defaultValue: currentDateAndTime);
  @override
  List<GeneratedColumn> get $columns =>
      [id, ledgerId, title, createdAt, updatedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'conversations';
  @override
  VerificationContext validateIntegrity(Insertable<Conversation> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('ledger_id')) {
      context.handle(_ledgerIdMeta,
          ledgerId.isAcceptableOrUnknown(data['ledger_id']!, _ledgerIdMeta));
    }
    if (data.containsKey('title')) {
      context.handle(
          _titleMeta, title.isAcceptableOrUnknown(data['title']!, _titleMeta));
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta,
          updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Conversation map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Conversation(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      ledgerId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}ledger_id']),
      title: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}title'])!,
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}created_at'])!,
      updatedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}updated_at'])!,
    );
  }

  @override
  $ConversationsTable createAlias(String alias) {
    return $ConversationsTable(attachedDatabase, alias);
  }
}

class Conversation extends DataClass implements Insertable<Conversation> {
  final int id;
  final int? ledgerId;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;
  const Conversation(
      {required this.id,
      this.ledgerId,
      required this.title,
      required this.createdAt,
      required this.updatedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    if (!nullToAbsent || ledgerId != null) {
      map['ledger_id'] = Variable<int>(ledgerId);
    }
    map['title'] = Variable<String>(title);
    map['created_at'] = Variable<DateTime>(createdAt);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    return map;
  }

  ConversationsCompanion toCompanion(bool nullToAbsent) {
    return ConversationsCompanion(
      id: Value(id),
      ledgerId: ledgerId == null && nullToAbsent
          ? const Value.absent()
          : Value(ledgerId),
      title: Value(title),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory Conversation.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Conversation(
      id: serializer.fromJson<int>(json['id']),
      ledgerId: serializer.fromJson<int?>(json['ledgerId']),
      title: serializer.fromJson<String>(json['title']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'ledgerId': serializer.toJson<int?>(ledgerId),
      'title': serializer.toJson<String>(title),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
    };
  }

  Conversation copyWith(
          {int? id,
          Value<int?> ledgerId = const Value.absent(),
          String? title,
          DateTime? createdAt,
          DateTime? updatedAt}) =>
      Conversation(
        id: id ?? this.id,
        ledgerId: ledgerId.present ? ledgerId.value : this.ledgerId,
        title: title ?? this.title,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );
  Conversation copyWithCompanion(ConversationsCompanion data) {
    return Conversation(
      id: data.id.present ? data.id.value : this.id,
      ledgerId: data.ledgerId.present ? data.ledgerId.value : this.ledgerId,
      title: data.title.present ? data.title.value : this.title,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Conversation(')
          ..write('id: $id, ')
          ..write('ledgerId: $ledgerId, ')
          ..write('title: $title, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, ledgerId, title, createdAt, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Conversation &&
          other.id == this.id &&
          other.ledgerId == this.ledgerId &&
          other.title == this.title &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class ConversationsCompanion extends UpdateCompanion<Conversation> {
  final Value<int> id;
  final Value<int?> ledgerId;
  final Value<String> title;
  final Value<DateTime> createdAt;
  final Value<DateTime> updatedAt;
  const ConversationsCompanion({
    this.id = const Value.absent(),
    this.ledgerId = const Value.absent(),
    this.title = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
  });
  ConversationsCompanion.insert({
    this.id = const Value.absent(),
    this.ledgerId = const Value.absent(),
    this.title = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
  });
  static Insertable<Conversation> custom({
    Expression<int>? id,
    Expression<int>? ledgerId,
    Expression<String>? title,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? updatedAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (ledgerId != null) 'ledger_id': ledgerId,
      if (title != null) 'title': title,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
    });
  }

  ConversationsCompanion copyWith(
      {Value<int>? id,
      Value<int?>? ledgerId,
      Value<String>? title,
      Value<DateTime>? createdAt,
      Value<DateTime>? updatedAt}) {
    return ConversationsCompanion(
      id: id ?? this.id,
      ledgerId: ledgerId ?? this.ledgerId,
      title: title ?? this.title,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (ledgerId.present) {
      map['ledger_id'] = Variable<int>(ledgerId.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ConversationsCompanion(')
          ..write('id: $id, ')
          ..write('ledgerId: $ledgerId, ')
          ..write('title: $title, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }
}

class $MessagesTable extends Messages with TableInfo<$MessagesTable, Message> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MessagesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _conversationIdMeta =
      const VerificationMeta('conversationId');
  @override
  late final GeneratedColumn<int> conversationId = GeneratedColumn<int>(
      'conversation_id', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _roleMeta = const VerificationMeta('role');
  @override
  late final GeneratedColumn<String> role = GeneratedColumn<String>(
      'role', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _contentMeta =
      const VerificationMeta('content');
  @override
  late final GeneratedColumn<String> content = GeneratedColumn<String>(
      'content', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _messageTypeMeta =
      const VerificationMeta('messageType');
  @override
  late final GeneratedColumn<String> messageType = GeneratedColumn<String>(
      'message_type', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _metadataMeta =
      const VerificationMeta('metadata');
  @override
  late final GeneratedColumn<String> metadata = GeneratedColumn<String>(
      'metadata', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _transactionIdMeta =
      const VerificationMeta('transactionId');
  @override
  late final GeneratedColumn<int> transactionId = GeneratedColumn<int>(
      'transaction_id', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
      'created_at', aliasedName, false,
      type: DriftSqlType.dateTime,
      requiredDuringInsert: false,
      defaultValue: currentDateAndTime);
  @override
  List<GeneratedColumn> get $columns => [
        id,
        conversationId,
        role,
        content,
        messageType,
        metadata,
        transactionId,
        createdAt
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'messages';
  @override
  VerificationContext validateIntegrity(Insertable<Message> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('conversation_id')) {
      context.handle(
          _conversationIdMeta,
          conversationId.isAcceptableOrUnknown(
              data['conversation_id']!, _conversationIdMeta));
    } else if (isInserting) {
      context.missing(_conversationIdMeta);
    }
    if (data.containsKey('role')) {
      context.handle(
          _roleMeta, role.isAcceptableOrUnknown(data['role']!, _roleMeta));
    } else if (isInserting) {
      context.missing(_roleMeta);
    }
    if (data.containsKey('content')) {
      context.handle(_contentMeta,
          content.isAcceptableOrUnknown(data['content']!, _contentMeta));
    } else if (isInserting) {
      context.missing(_contentMeta);
    }
    if (data.containsKey('message_type')) {
      context.handle(
          _messageTypeMeta,
          messageType.isAcceptableOrUnknown(
              data['message_type']!, _messageTypeMeta));
    } else if (isInserting) {
      context.missing(_messageTypeMeta);
    }
    if (data.containsKey('metadata')) {
      context.handle(_metadataMeta,
          metadata.isAcceptableOrUnknown(data['metadata']!, _metadataMeta));
    }
    if (data.containsKey('transaction_id')) {
      context.handle(
          _transactionIdMeta,
          transactionId.isAcceptableOrUnknown(
              data['transaction_id']!, _transactionIdMeta));
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Message map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Message(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      conversationId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}conversation_id'])!,
      role: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}role'])!,
      content: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}content'])!,
      messageType: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}message_type'])!,
      metadata: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}metadata']),
      transactionId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}transaction_id']),
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}created_at'])!,
    );
  }

  @override
  $MessagesTable createAlias(String alias) {
    return $MessagesTable(attachedDatabase, alias);
  }
}

class Message extends DataClass implements Insertable<Message> {
  final int id;
  final int conversationId;
  final String role;
  final String content;
  final String messageType;
  final String? metadata;
  final int? transactionId;
  final DateTime createdAt;
  const Message(
      {required this.id,
      required this.conversationId,
      required this.role,
      required this.content,
      required this.messageType,
      this.metadata,
      this.transactionId,
      required this.createdAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['conversation_id'] = Variable<int>(conversationId);
    map['role'] = Variable<String>(role);
    map['content'] = Variable<String>(content);
    map['message_type'] = Variable<String>(messageType);
    if (!nullToAbsent || metadata != null) {
      map['metadata'] = Variable<String>(metadata);
    }
    if (!nullToAbsent || transactionId != null) {
      map['transaction_id'] = Variable<int>(transactionId);
    }
    map['created_at'] = Variable<DateTime>(createdAt);
    return map;
  }

  MessagesCompanion toCompanion(bool nullToAbsent) {
    return MessagesCompanion(
      id: Value(id),
      conversationId: Value(conversationId),
      role: Value(role),
      content: Value(content),
      messageType: Value(messageType),
      metadata: metadata == null && nullToAbsent
          ? const Value.absent()
          : Value(metadata),
      transactionId: transactionId == null && nullToAbsent
          ? const Value.absent()
          : Value(transactionId),
      createdAt: Value(createdAt),
    );
  }

  factory Message.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Message(
      id: serializer.fromJson<int>(json['id']),
      conversationId: serializer.fromJson<int>(json['conversationId']),
      role: serializer.fromJson<String>(json['role']),
      content: serializer.fromJson<String>(json['content']),
      messageType: serializer.fromJson<String>(json['messageType']),
      metadata: serializer.fromJson<String?>(json['metadata']),
      transactionId: serializer.fromJson<int?>(json['transactionId']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'conversationId': serializer.toJson<int>(conversationId),
      'role': serializer.toJson<String>(role),
      'content': serializer.toJson<String>(content),
      'messageType': serializer.toJson<String>(messageType),
      'metadata': serializer.toJson<String?>(metadata),
      'transactionId': serializer.toJson<int?>(transactionId),
      'createdAt': serializer.toJson<DateTime>(createdAt),
    };
  }

  Message copyWith(
          {int? id,
          int? conversationId,
          String? role,
          String? content,
          String? messageType,
          Value<String?> metadata = const Value.absent(),
          Value<int?> transactionId = const Value.absent(),
          DateTime? createdAt}) =>
      Message(
        id: id ?? this.id,
        conversationId: conversationId ?? this.conversationId,
        role: role ?? this.role,
        content: content ?? this.content,
        messageType: messageType ?? this.messageType,
        metadata: metadata.present ? metadata.value : this.metadata,
        transactionId:
            transactionId.present ? transactionId.value : this.transactionId,
        createdAt: createdAt ?? this.createdAt,
      );
  Message copyWithCompanion(MessagesCompanion data) {
    return Message(
      id: data.id.present ? data.id.value : this.id,
      conversationId: data.conversationId.present
          ? data.conversationId.value
          : this.conversationId,
      role: data.role.present ? data.role.value : this.role,
      content: data.content.present ? data.content.value : this.content,
      messageType:
          data.messageType.present ? data.messageType.value : this.messageType,
      metadata: data.metadata.present ? data.metadata.value : this.metadata,
      transactionId: data.transactionId.present
          ? data.transactionId.value
          : this.transactionId,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Message(')
          ..write('id: $id, ')
          ..write('conversationId: $conversationId, ')
          ..write('role: $role, ')
          ..write('content: $content, ')
          ..write('messageType: $messageType, ')
          ..write('metadata: $metadata, ')
          ..write('transactionId: $transactionId, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, conversationId, role, content,
      messageType, metadata, transactionId, createdAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Message &&
          other.id == this.id &&
          other.conversationId == this.conversationId &&
          other.role == this.role &&
          other.content == this.content &&
          other.messageType == this.messageType &&
          other.metadata == this.metadata &&
          other.transactionId == this.transactionId &&
          other.createdAt == this.createdAt);
}

class MessagesCompanion extends UpdateCompanion<Message> {
  final Value<int> id;
  final Value<int> conversationId;
  final Value<String> role;
  final Value<String> content;
  final Value<String> messageType;
  final Value<String?> metadata;
  final Value<int?> transactionId;
  final Value<DateTime> createdAt;
  const MessagesCompanion({
    this.id = const Value.absent(),
    this.conversationId = const Value.absent(),
    this.role = const Value.absent(),
    this.content = const Value.absent(),
    this.messageType = const Value.absent(),
    this.metadata = const Value.absent(),
    this.transactionId = const Value.absent(),
    this.createdAt = const Value.absent(),
  });
  MessagesCompanion.insert({
    this.id = const Value.absent(),
    required int conversationId,
    required String role,
    required String content,
    required String messageType,
    this.metadata = const Value.absent(),
    this.transactionId = const Value.absent(),
    this.createdAt = const Value.absent(),
  })  : conversationId = Value(conversationId),
        role = Value(role),
        content = Value(content),
        messageType = Value(messageType);
  static Insertable<Message> custom({
    Expression<int>? id,
    Expression<int>? conversationId,
    Expression<String>? role,
    Expression<String>? content,
    Expression<String>? messageType,
    Expression<String>? metadata,
    Expression<int>? transactionId,
    Expression<DateTime>? createdAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (conversationId != null) 'conversation_id': conversationId,
      if (role != null) 'role': role,
      if (content != null) 'content': content,
      if (messageType != null) 'message_type': messageType,
      if (metadata != null) 'metadata': metadata,
      if (transactionId != null) 'transaction_id': transactionId,
      if (createdAt != null) 'created_at': createdAt,
    });
  }

  MessagesCompanion copyWith(
      {Value<int>? id,
      Value<int>? conversationId,
      Value<String>? role,
      Value<String>? content,
      Value<String>? messageType,
      Value<String?>? metadata,
      Value<int?>? transactionId,
      Value<DateTime>? createdAt}) {
    return MessagesCompanion(
      id: id ?? this.id,
      conversationId: conversationId ?? this.conversationId,
      role: role ?? this.role,
      content: content ?? this.content,
      messageType: messageType ?? this.messageType,
      metadata: metadata ?? this.metadata,
      transactionId: transactionId ?? this.transactionId,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (conversationId.present) {
      map['conversation_id'] = Variable<int>(conversationId.value);
    }
    if (role.present) {
      map['role'] = Variable<String>(role.value);
    }
    if (content.present) {
      map['content'] = Variable<String>(content.value);
    }
    if (messageType.present) {
      map['message_type'] = Variable<String>(messageType.value);
    }
    if (metadata.present) {
      map['metadata'] = Variable<String>(metadata.value);
    }
    if (transactionId.present) {
      map['transaction_id'] = Variable<int>(transactionId.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MessagesCompanion(')
          ..write('id: $id, ')
          ..write('conversationId: $conversationId, ')
          ..write('role: $role, ')
          ..write('content: $content, ')
          ..write('messageType: $messageType, ')
          ..write('metadata: $metadata, ')
          ..write('transactionId: $transactionId, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }
}

class $TagsTable extends Tags with TableInfo<$TagsTable, Tag> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $TagsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
      'name', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _colorMeta = const VerificationMeta('color');
  @override
  late final GeneratedColumn<String> color = GeneratedColumn<String>(
      'color', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _sortOrderMeta =
      const VerificationMeta('sortOrder');
  @override
  late final GeneratedColumn<int> sortOrder = GeneratedColumn<int>(
      'sort_order', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
      'created_at', aliasedName, false,
      type: DriftSqlType.dateTime,
      requiredDuringInsert: false,
      defaultValue: currentDateAndTime);
  static const VerificationMeta _syncIdMeta = const VerificationMeta('syncId');
  @override
  late final GeneratedColumn<String> syncId = GeneratedColumn<String>(
      'sync_id', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _updatedAtMeta =
      const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
      'updated_at', aliasedName, true,
      type: DriftSqlType.dateTime, requiredDuringInsert: false);
  @override
  List<GeneratedColumn> get $columns =>
      [id, name, color, sortOrder, createdAt, syncId, updatedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'tags';
  @override
  VerificationContext validateIntegrity(Insertable<Tag> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('name')) {
      context.handle(
          _nameMeta, name.isAcceptableOrUnknown(data['name']!, _nameMeta));
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('color')) {
      context.handle(
          _colorMeta, color.isAcceptableOrUnknown(data['color']!, _colorMeta));
    }
    if (data.containsKey('sort_order')) {
      context.handle(_sortOrderMeta,
          sortOrder.isAcceptableOrUnknown(data['sort_order']!, _sortOrderMeta));
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    }
    if (data.containsKey('sync_id')) {
      context.handle(_syncIdMeta,
          syncId.isAcceptableOrUnknown(data['sync_id']!, _syncIdMeta));
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta,
          updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Tag map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Tag(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      name: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}name'])!,
      color: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}color']),
      sortOrder: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}sort_order'])!,
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}created_at'])!,
      syncId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}sync_id']),
      updatedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}updated_at']),
    );
  }

  @override
  $TagsTable createAlias(String alias) {
    return $TagsTable(attachedDatabase, alias);
  }
}

class Tag extends DataClass implements Insertable<Tag> {
  final int id;
  final String name;
  final String? color;
  final int sortOrder;
  final DateTime createdAt;
  final String? syncId;

  /// 审计 T1（v40）：见 Ledgers.updatedAt 注释。触发器
  /// trg_tags_touch_updated_at 自动维护。
  final DateTime? updatedAt;
  const Tag(
      {required this.id,
      required this.name,
      this.color,
      required this.sortOrder,
      required this.createdAt,
      this.syncId,
      this.updatedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['name'] = Variable<String>(name);
    if (!nullToAbsent || color != null) {
      map['color'] = Variable<String>(color);
    }
    map['sort_order'] = Variable<int>(sortOrder);
    map['created_at'] = Variable<DateTime>(createdAt);
    if (!nullToAbsent || syncId != null) {
      map['sync_id'] = Variable<String>(syncId);
    }
    if (!nullToAbsent || updatedAt != null) {
      map['updated_at'] = Variable<DateTime>(updatedAt);
    }
    return map;
  }

  TagsCompanion toCompanion(bool nullToAbsent) {
    return TagsCompanion(
      id: Value(id),
      name: Value(name),
      color:
          color == null && nullToAbsent ? const Value.absent() : Value(color),
      sortOrder: Value(sortOrder),
      createdAt: Value(createdAt),
      syncId:
          syncId == null && nullToAbsent ? const Value.absent() : Value(syncId),
      updatedAt: updatedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(updatedAt),
    );
  }

  factory Tag.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Tag(
      id: serializer.fromJson<int>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      color: serializer.fromJson<String?>(json['color']),
      sortOrder: serializer.fromJson<int>(json['sortOrder']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      syncId: serializer.fromJson<String?>(json['syncId']),
      updatedAt: serializer.fromJson<DateTime?>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'name': serializer.toJson<String>(name),
      'color': serializer.toJson<String?>(color),
      'sortOrder': serializer.toJson<int>(sortOrder),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'syncId': serializer.toJson<String?>(syncId),
      'updatedAt': serializer.toJson<DateTime?>(updatedAt),
    };
  }

  Tag copyWith(
          {int? id,
          String? name,
          Value<String?> color = const Value.absent(),
          int? sortOrder,
          DateTime? createdAt,
          Value<String?> syncId = const Value.absent(),
          Value<DateTime?> updatedAt = const Value.absent()}) =>
      Tag(
        id: id ?? this.id,
        name: name ?? this.name,
        color: color.present ? color.value : this.color,
        sortOrder: sortOrder ?? this.sortOrder,
        createdAt: createdAt ?? this.createdAt,
        syncId: syncId.present ? syncId.value : this.syncId,
        updatedAt: updatedAt.present ? updatedAt.value : this.updatedAt,
      );
  Tag copyWithCompanion(TagsCompanion data) {
    return Tag(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      color: data.color.present ? data.color.value : this.color,
      sortOrder: data.sortOrder.present ? data.sortOrder.value : this.sortOrder,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      syncId: data.syncId.present ? data.syncId.value : this.syncId,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Tag(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('color: $color, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('createdAt: $createdAt, ')
          ..write('syncId: $syncId, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, name, color, sortOrder, createdAt, syncId, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Tag &&
          other.id == this.id &&
          other.name == this.name &&
          other.color == this.color &&
          other.sortOrder == this.sortOrder &&
          other.createdAt == this.createdAt &&
          other.syncId == this.syncId &&
          other.updatedAt == this.updatedAt);
}

class TagsCompanion extends UpdateCompanion<Tag> {
  final Value<int> id;
  final Value<String> name;
  final Value<String?> color;
  final Value<int> sortOrder;
  final Value<DateTime> createdAt;
  final Value<String?> syncId;
  final Value<DateTime?> updatedAt;
  const TagsCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.color = const Value.absent(),
    this.sortOrder = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.syncId = const Value.absent(),
    this.updatedAt = const Value.absent(),
  });
  TagsCompanion.insert({
    this.id = const Value.absent(),
    required String name,
    this.color = const Value.absent(),
    this.sortOrder = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.syncId = const Value.absent(),
    this.updatedAt = const Value.absent(),
  }) : name = Value(name);
  static Insertable<Tag> custom({
    Expression<int>? id,
    Expression<String>? name,
    Expression<String>? color,
    Expression<int>? sortOrder,
    Expression<DateTime>? createdAt,
    Expression<String>? syncId,
    Expression<DateTime>? updatedAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (color != null) 'color': color,
      if (sortOrder != null) 'sort_order': sortOrder,
      if (createdAt != null) 'created_at': createdAt,
      if (syncId != null) 'sync_id': syncId,
      if (updatedAt != null) 'updated_at': updatedAt,
    });
  }

  TagsCompanion copyWith(
      {Value<int>? id,
      Value<String>? name,
      Value<String?>? color,
      Value<int>? sortOrder,
      Value<DateTime>? createdAt,
      Value<String?>? syncId,
      Value<DateTime?>? updatedAt}) {
    return TagsCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      color: color ?? this.color,
      sortOrder: sortOrder ?? this.sortOrder,
      createdAt: createdAt ?? this.createdAt,
      syncId: syncId ?? this.syncId,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (color.present) {
      map['color'] = Variable<String>(color.value);
    }
    if (sortOrder.present) {
      map['sort_order'] = Variable<int>(sortOrder.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (syncId.present) {
      map['sync_id'] = Variable<String>(syncId.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('TagsCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('color: $color, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('createdAt: $createdAt, ')
          ..write('syncId: $syncId, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }
}

class $CustomFieldDefinitionsTable extends CustomFieldDefinitions
    with TableInfo<$CustomFieldDefinitionsTable, CustomFieldDefinition> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CustomFieldDefinitionsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _ledgerIdMeta =
      const VerificationMeta('ledgerId');
  @override
  late final GeneratedColumn<int> ledgerId = GeneratedColumn<int>(
      'ledger_id', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
      'name', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _fieldTypeMeta =
      const VerificationMeta('fieldType');
  @override
  late final GeneratedColumn<String> fieldType = GeneratedColumn<String>(
      'field_type', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _sortOrderMeta =
      const VerificationMeta('sortOrder');
  @override
  late final GeneratedColumn<int> sortOrder = GeneratedColumn<int>(
      'sort_order', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
      'created_at', aliasedName, false,
      type: DriftSqlType.dateTime,
      requiredDuringInsert: false,
      defaultValue: currentDateAndTime);
  static const VerificationMeta _syncIdMeta = const VerificationMeta('syncId');
  @override
  late final GeneratedColumn<String> syncId = GeneratedColumn<String>(
      'sync_id', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _updatedAtMeta =
      const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
      'updated_at', aliasedName, true,
      type: DriftSqlType.dateTime, requiredDuringInsert: false);
  @override
  List<GeneratedColumn> get $columns =>
      [id, ledgerId, name, fieldType, sortOrder, createdAt, syncId, updatedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'custom_field_definitions';
  @override
  VerificationContext validateIntegrity(
      Insertable<CustomFieldDefinition> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('ledger_id')) {
      context.handle(_ledgerIdMeta,
          ledgerId.isAcceptableOrUnknown(data['ledger_id']!, _ledgerIdMeta));
    } else if (isInserting) {
      context.missing(_ledgerIdMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
          _nameMeta, name.isAcceptableOrUnknown(data['name']!, _nameMeta));
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('field_type')) {
      context.handle(_fieldTypeMeta,
          fieldType.isAcceptableOrUnknown(data['field_type']!, _fieldTypeMeta));
    } else if (isInserting) {
      context.missing(_fieldTypeMeta);
    }
    if (data.containsKey('sort_order')) {
      context.handle(_sortOrderMeta,
          sortOrder.isAcceptableOrUnknown(data['sort_order']!, _sortOrderMeta));
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    }
    if (data.containsKey('sync_id')) {
      context.handle(_syncIdMeta,
          syncId.isAcceptableOrUnknown(data['sync_id']!, _syncIdMeta));
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta,
          updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  CustomFieldDefinition map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CustomFieldDefinition(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      ledgerId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}ledger_id'])!,
      name: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}name'])!,
      fieldType: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}field_type'])!,
      sortOrder: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}sort_order'])!,
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}created_at'])!,
      syncId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}sync_id']),
      updatedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}updated_at']),
    );
  }

  @override
  $CustomFieldDefinitionsTable createAlias(String alias) {
    return $CustomFieldDefinitionsTable(attachedDatabase, alias);
  }
}

class CustomFieldDefinition extends DataClass
    implements Insertable<CustomFieldDefinition> {
  final int id;

  /// 所属账本:字段定义按账本隔离,账本 A 的字段不会出现在账本 B。
  final int ledgerId;

  /// 用户自定义字段名(同账本内不重名,由应用层校验)。
  final String name;

  /// amount / text / date。字符串存储以便后续扩展新类型。
  final String fieldType;

  /// 展示与录入门槛顺序,数字越小越靠前(与 Categories/Tags.sortOrder 同义)。
  final int sortOrder;
  final DateTime createdAt;

  /// 跨设备同步唯一标识 (UUID)。字段值的 JSON 键就是本列。
  final String? syncId;

  /// 审计 T1（v40）：见 Ledgers.updatedAt 注释。触发器
  /// trg_custom_field_definitions_touch_updated_at 自动维护。
  final DateTime? updatedAt;
  const CustomFieldDefinition(
      {required this.id,
      required this.ledgerId,
      required this.name,
      required this.fieldType,
      required this.sortOrder,
      required this.createdAt,
      this.syncId,
      this.updatedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['ledger_id'] = Variable<int>(ledgerId);
    map['name'] = Variable<String>(name);
    map['field_type'] = Variable<String>(fieldType);
    map['sort_order'] = Variable<int>(sortOrder);
    map['created_at'] = Variable<DateTime>(createdAt);
    if (!nullToAbsent || syncId != null) {
      map['sync_id'] = Variable<String>(syncId);
    }
    if (!nullToAbsent || updatedAt != null) {
      map['updated_at'] = Variable<DateTime>(updatedAt);
    }
    return map;
  }

  CustomFieldDefinitionsCompanion toCompanion(bool nullToAbsent) {
    return CustomFieldDefinitionsCompanion(
      id: Value(id),
      ledgerId: Value(ledgerId),
      name: Value(name),
      fieldType: Value(fieldType),
      sortOrder: Value(sortOrder),
      createdAt: Value(createdAt),
      syncId:
          syncId == null && nullToAbsent ? const Value.absent() : Value(syncId),
      updatedAt: updatedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(updatedAt),
    );
  }

  factory CustomFieldDefinition.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CustomFieldDefinition(
      id: serializer.fromJson<int>(json['id']),
      ledgerId: serializer.fromJson<int>(json['ledgerId']),
      name: serializer.fromJson<String>(json['name']),
      fieldType: serializer.fromJson<String>(json['fieldType']),
      sortOrder: serializer.fromJson<int>(json['sortOrder']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      syncId: serializer.fromJson<String?>(json['syncId']),
      updatedAt: serializer.fromJson<DateTime?>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'ledgerId': serializer.toJson<int>(ledgerId),
      'name': serializer.toJson<String>(name),
      'fieldType': serializer.toJson<String>(fieldType),
      'sortOrder': serializer.toJson<int>(sortOrder),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'syncId': serializer.toJson<String?>(syncId),
      'updatedAt': serializer.toJson<DateTime?>(updatedAt),
    };
  }

  CustomFieldDefinition copyWith(
          {int? id,
          int? ledgerId,
          String? name,
          String? fieldType,
          int? sortOrder,
          DateTime? createdAt,
          Value<String?> syncId = const Value.absent(),
          Value<DateTime?> updatedAt = const Value.absent()}) =>
      CustomFieldDefinition(
        id: id ?? this.id,
        ledgerId: ledgerId ?? this.ledgerId,
        name: name ?? this.name,
        fieldType: fieldType ?? this.fieldType,
        sortOrder: sortOrder ?? this.sortOrder,
        createdAt: createdAt ?? this.createdAt,
        syncId: syncId.present ? syncId.value : this.syncId,
        updatedAt: updatedAt.present ? updatedAt.value : this.updatedAt,
      );
  CustomFieldDefinition copyWithCompanion(
      CustomFieldDefinitionsCompanion data) {
    return CustomFieldDefinition(
      id: data.id.present ? data.id.value : this.id,
      ledgerId: data.ledgerId.present ? data.ledgerId.value : this.ledgerId,
      name: data.name.present ? data.name.value : this.name,
      fieldType: data.fieldType.present ? data.fieldType.value : this.fieldType,
      sortOrder: data.sortOrder.present ? data.sortOrder.value : this.sortOrder,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      syncId: data.syncId.present ? data.syncId.value : this.syncId,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CustomFieldDefinition(')
          ..write('id: $id, ')
          ..write('ledgerId: $ledgerId, ')
          ..write('name: $name, ')
          ..write('fieldType: $fieldType, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('createdAt: $createdAt, ')
          ..write('syncId: $syncId, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      id, ledgerId, name, fieldType, sortOrder, createdAt, syncId, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CustomFieldDefinition &&
          other.id == this.id &&
          other.ledgerId == this.ledgerId &&
          other.name == this.name &&
          other.fieldType == this.fieldType &&
          other.sortOrder == this.sortOrder &&
          other.createdAt == this.createdAt &&
          other.syncId == this.syncId &&
          other.updatedAt == this.updatedAt);
}

class CustomFieldDefinitionsCompanion
    extends UpdateCompanion<CustomFieldDefinition> {
  final Value<int> id;
  final Value<int> ledgerId;
  final Value<String> name;
  final Value<String> fieldType;
  final Value<int> sortOrder;
  final Value<DateTime> createdAt;
  final Value<String?> syncId;
  final Value<DateTime?> updatedAt;
  const CustomFieldDefinitionsCompanion({
    this.id = const Value.absent(),
    this.ledgerId = const Value.absent(),
    this.name = const Value.absent(),
    this.fieldType = const Value.absent(),
    this.sortOrder = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.syncId = const Value.absent(),
    this.updatedAt = const Value.absent(),
  });
  CustomFieldDefinitionsCompanion.insert({
    this.id = const Value.absent(),
    required int ledgerId,
    required String name,
    required String fieldType,
    this.sortOrder = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.syncId = const Value.absent(),
    this.updatedAt = const Value.absent(),
  })  : ledgerId = Value(ledgerId),
        name = Value(name),
        fieldType = Value(fieldType);
  static Insertable<CustomFieldDefinition> custom({
    Expression<int>? id,
    Expression<int>? ledgerId,
    Expression<String>? name,
    Expression<String>? fieldType,
    Expression<int>? sortOrder,
    Expression<DateTime>? createdAt,
    Expression<String>? syncId,
    Expression<DateTime>? updatedAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (ledgerId != null) 'ledger_id': ledgerId,
      if (name != null) 'name': name,
      if (fieldType != null) 'field_type': fieldType,
      if (sortOrder != null) 'sort_order': sortOrder,
      if (createdAt != null) 'created_at': createdAt,
      if (syncId != null) 'sync_id': syncId,
      if (updatedAt != null) 'updated_at': updatedAt,
    });
  }

  CustomFieldDefinitionsCompanion copyWith(
      {Value<int>? id,
      Value<int>? ledgerId,
      Value<String>? name,
      Value<String>? fieldType,
      Value<int>? sortOrder,
      Value<DateTime>? createdAt,
      Value<String?>? syncId,
      Value<DateTime?>? updatedAt}) {
    return CustomFieldDefinitionsCompanion(
      id: id ?? this.id,
      ledgerId: ledgerId ?? this.ledgerId,
      name: name ?? this.name,
      fieldType: fieldType ?? this.fieldType,
      sortOrder: sortOrder ?? this.sortOrder,
      createdAt: createdAt ?? this.createdAt,
      syncId: syncId ?? this.syncId,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (ledgerId.present) {
      map['ledger_id'] = Variable<int>(ledgerId.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (fieldType.present) {
      map['field_type'] = Variable<String>(fieldType.value);
    }
    if (sortOrder.present) {
      map['sort_order'] = Variable<int>(sortOrder.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (syncId.present) {
      map['sync_id'] = Variable<String>(syncId.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CustomFieldDefinitionsCompanion(')
          ..write('id: $id, ')
          ..write('ledgerId: $ledgerId, ')
          ..write('name: $name, ')
          ..write('fieldType: $fieldType, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('createdAt: $createdAt, ')
          ..write('syncId: $syncId, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }
}

class $TransactionTagsTable extends TransactionTags
    with TableInfo<$TransactionTagsTable, TransactionTag> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $TransactionTagsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _transactionIdMeta =
      const VerificationMeta('transactionId');
  @override
  late final GeneratedColumn<int> transactionId = GeneratedColumn<int>(
      'transaction_id', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _tagIdMeta = const VerificationMeta('tagId');
  @override
  late final GeneratedColumn<int> tagId = GeneratedColumn<int>(
      'tag_id', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [id, transactionId, tagId];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'transaction_tags';
  @override
  VerificationContext validateIntegrity(Insertable<TransactionTag> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('transaction_id')) {
      context.handle(
          _transactionIdMeta,
          transactionId.isAcceptableOrUnknown(
              data['transaction_id']!, _transactionIdMeta));
    } else if (isInserting) {
      context.missing(_transactionIdMeta);
    }
    if (data.containsKey('tag_id')) {
      context.handle(
          _tagIdMeta, tagId.isAcceptableOrUnknown(data['tag_id']!, _tagIdMeta));
    } else if (isInserting) {
      context.missing(_tagIdMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  TransactionTag map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return TransactionTag(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      transactionId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}transaction_id'])!,
      tagId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}tag_id'])!,
    );
  }

  @override
  $TransactionTagsTable createAlias(String alias) {
    return $TransactionTagsTable(attachedDatabase, alias);
  }
}

class TransactionTag extends DataClass implements Insertable<TransactionTag> {
  final int id;
  final int transactionId;
  final int tagId;
  const TransactionTag(
      {required this.id, required this.transactionId, required this.tagId});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['transaction_id'] = Variable<int>(transactionId);
    map['tag_id'] = Variable<int>(tagId);
    return map;
  }

  TransactionTagsCompanion toCompanion(bool nullToAbsent) {
    return TransactionTagsCompanion(
      id: Value(id),
      transactionId: Value(transactionId),
      tagId: Value(tagId),
    );
  }

  factory TransactionTag.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return TransactionTag(
      id: serializer.fromJson<int>(json['id']),
      transactionId: serializer.fromJson<int>(json['transactionId']),
      tagId: serializer.fromJson<int>(json['tagId']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'transactionId': serializer.toJson<int>(transactionId),
      'tagId': serializer.toJson<int>(tagId),
    };
  }

  TransactionTag copyWith({int? id, int? transactionId, int? tagId}) =>
      TransactionTag(
        id: id ?? this.id,
        transactionId: transactionId ?? this.transactionId,
        tagId: tagId ?? this.tagId,
      );
  TransactionTag copyWithCompanion(TransactionTagsCompanion data) {
    return TransactionTag(
      id: data.id.present ? data.id.value : this.id,
      transactionId: data.transactionId.present
          ? data.transactionId.value
          : this.transactionId,
      tagId: data.tagId.present ? data.tagId.value : this.tagId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('TransactionTag(')
          ..write('id: $id, ')
          ..write('transactionId: $transactionId, ')
          ..write('tagId: $tagId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, transactionId, tagId);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TransactionTag &&
          other.id == this.id &&
          other.transactionId == this.transactionId &&
          other.tagId == this.tagId);
}

class TransactionTagsCompanion extends UpdateCompanion<TransactionTag> {
  final Value<int> id;
  final Value<int> transactionId;
  final Value<int> tagId;
  const TransactionTagsCompanion({
    this.id = const Value.absent(),
    this.transactionId = const Value.absent(),
    this.tagId = const Value.absent(),
  });
  TransactionTagsCompanion.insert({
    this.id = const Value.absent(),
    required int transactionId,
    required int tagId,
  })  : transactionId = Value(transactionId),
        tagId = Value(tagId);
  static Insertable<TransactionTag> custom({
    Expression<int>? id,
    Expression<int>? transactionId,
    Expression<int>? tagId,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (transactionId != null) 'transaction_id': transactionId,
      if (tagId != null) 'tag_id': tagId,
    });
  }

  TransactionTagsCompanion copyWith(
      {Value<int>? id, Value<int>? transactionId, Value<int>? tagId}) {
    return TransactionTagsCompanion(
      id: id ?? this.id,
      transactionId: transactionId ?? this.transactionId,
      tagId: tagId ?? this.tagId,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (transactionId.present) {
      map['transaction_id'] = Variable<int>(transactionId.value);
    }
    if (tagId.present) {
      map['tag_id'] = Variable<int>(tagId.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('TransactionTagsCompanion(')
          ..write('id: $id, ')
          ..write('transactionId: $transactionId, ')
          ..write('tagId: $tagId')
          ..write(')'))
        .toString();
  }
}

class $BudgetsTable extends Budgets with TableInfo<$BudgetsTable, Budget> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $BudgetsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _syncIdMeta = const VerificationMeta('syncId');
  @override
  late final GeneratedColumn<String> syncId = GeneratedColumn<String>(
      'sync_id', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _ledgerIdMeta =
      const VerificationMeta('ledgerId');
  @override
  late final GeneratedColumn<int> ledgerId = GeneratedColumn<int>(
      'ledger_id', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _typeMeta = const VerificationMeta('type');
  @override
  late final GeneratedColumn<String> type = GeneratedColumn<String>(
      'type', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('total'));
  static const VerificationMeta _categoryIdMeta =
      const VerificationMeta('categoryId');
  @override
  late final GeneratedColumn<int> categoryId = GeneratedColumn<int>(
      'category_id', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _amountMeta = const VerificationMeta('amount');
  @override
  late final GeneratedColumn<double> amount = GeneratedColumn<double>(
      'amount', aliasedName, false,
      type: DriftSqlType.double, requiredDuringInsert: true);
  static const VerificationMeta _periodMeta = const VerificationMeta('period');
  @override
  late final GeneratedColumn<String> period = GeneratedColumn<String>(
      'period', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('monthly'));
  static const VerificationMeta _startDayMeta =
      const VerificationMeta('startDay');
  @override
  late final GeneratedColumn<int> startDay = GeneratedColumn<int>(
      'start_day', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(1));
  static const VerificationMeta _enabledMeta =
      const VerificationMeta('enabled');
  @override
  late final GeneratedColumn<bool> enabled = GeneratedColumn<bool>(
      'enabled', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("enabled" IN (0, 1))'),
      defaultValue: const Constant(true));
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
      'created_at', aliasedName, false,
      type: DriftSqlType.dateTime,
      requiredDuringInsert: false,
      defaultValue: currentDateAndTime);
  static const VerificationMeta _updatedAtMeta =
      const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
      'updated_at', aliasedName, false,
      type: DriftSqlType.dateTime,
      requiredDuringInsert: false,
      defaultValue: currentDateAndTime);
  @override
  List<GeneratedColumn> get $columns => [
        id,
        syncId,
        ledgerId,
        type,
        categoryId,
        amount,
        period,
        startDay,
        enabled,
        createdAt,
        updatedAt
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'budgets';
  @override
  VerificationContext validateIntegrity(Insertable<Budget> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('sync_id')) {
      context.handle(_syncIdMeta,
          syncId.isAcceptableOrUnknown(data['sync_id']!, _syncIdMeta));
    }
    if (data.containsKey('ledger_id')) {
      context.handle(_ledgerIdMeta,
          ledgerId.isAcceptableOrUnknown(data['ledger_id']!, _ledgerIdMeta));
    } else if (isInserting) {
      context.missing(_ledgerIdMeta);
    }
    if (data.containsKey('type')) {
      context.handle(
          _typeMeta, type.isAcceptableOrUnknown(data['type']!, _typeMeta));
    }
    if (data.containsKey('category_id')) {
      context.handle(
          _categoryIdMeta,
          categoryId.isAcceptableOrUnknown(
              data['category_id']!, _categoryIdMeta));
    }
    if (data.containsKey('amount')) {
      context.handle(_amountMeta,
          amount.isAcceptableOrUnknown(data['amount']!, _amountMeta));
    } else if (isInserting) {
      context.missing(_amountMeta);
    }
    if (data.containsKey('period')) {
      context.handle(_periodMeta,
          period.isAcceptableOrUnknown(data['period']!, _periodMeta));
    }
    if (data.containsKey('start_day')) {
      context.handle(_startDayMeta,
          startDay.isAcceptableOrUnknown(data['start_day']!, _startDayMeta));
    }
    if (data.containsKey('enabled')) {
      context.handle(_enabledMeta,
          enabled.isAcceptableOrUnknown(data['enabled']!, _enabledMeta));
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta,
          updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Budget map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Budget(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      syncId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}sync_id']),
      ledgerId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}ledger_id'])!,
      type: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}type'])!,
      categoryId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}category_id']),
      amount: attachedDatabase.typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}amount'])!,
      period: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}period'])!,
      startDay: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}start_day'])!,
      enabled: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}enabled'])!,
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}created_at'])!,
      updatedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}updated_at'])!,
    );
  }

  @override
  $BudgetsTable createAlias(String alias) {
    return $BudgetsTable(attachedDatabase, alias);
  }
}

class Budget extends DataClass implements Insertable<Budget> {
  final int id;

  /// 跨设备同步 syncId(UUID)。v22 新增,migration 给老行补 UUID;之后每次 create
  /// 都必须填。server 端按此做 entity_sync_id,跨设备 LWW 合并。
  final String? syncId;

  /// 关联账本ID
  final int ledgerId;

  /// 预算类型：total-总预算, category-分类预算
  final String type;

  /// 关联分类ID（仅分类预算有值）
  final int? categoryId;

  /// 预算金额
  final double amount;

  /// 预算周期：monthly-月度, weekly-周度, yearly-年度
  final String period;

  /// 周期起始日（1-31，月度预算；1-7，周度预算）
  final int startDay;

  /// 是否启用
  final bool enabled;

  /// 创建时间
  final DateTime createdAt;

  /// 更新时间
  final DateTime updatedAt;
  const Budget(
      {required this.id,
      this.syncId,
      required this.ledgerId,
      required this.type,
      this.categoryId,
      required this.amount,
      required this.period,
      required this.startDay,
      required this.enabled,
      required this.createdAt,
      required this.updatedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    if (!nullToAbsent || syncId != null) {
      map['sync_id'] = Variable<String>(syncId);
    }
    map['ledger_id'] = Variable<int>(ledgerId);
    map['type'] = Variable<String>(type);
    if (!nullToAbsent || categoryId != null) {
      map['category_id'] = Variable<int>(categoryId);
    }
    map['amount'] = Variable<double>(amount);
    map['period'] = Variable<String>(period);
    map['start_day'] = Variable<int>(startDay);
    map['enabled'] = Variable<bool>(enabled);
    map['created_at'] = Variable<DateTime>(createdAt);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    return map;
  }

  BudgetsCompanion toCompanion(bool nullToAbsent) {
    return BudgetsCompanion(
      id: Value(id),
      syncId:
          syncId == null && nullToAbsent ? const Value.absent() : Value(syncId),
      ledgerId: Value(ledgerId),
      type: Value(type),
      categoryId: categoryId == null && nullToAbsent
          ? const Value.absent()
          : Value(categoryId),
      amount: Value(amount),
      period: Value(period),
      startDay: Value(startDay),
      enabled: Value(enabled),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory Budget.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Budget(
      id: serializer.fromJson<int>(json['id']),
      syncId: serializer.fromJson<String?>(json['syncId']),
      ledgerId: serializer.fromJson<int>(json['ledgerId']),
      type: serializer.fromJson<String>(json['type']),
      categoryId: serializer.fromJson<int?>(json['categoryId']),
      amount: serializer.fromJson<double>(json['amount']),
      period: serializer.fromJson<String>(json['period']),
      startDay: serializer.fromJson<int>(json['startDay']),
      enabled: serializer.fromJson<bool>(json['enabled']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'syncId': serializer.toJson<String?>(syncId),
      'ledgerId': serializer.toJson<int>(ledgerId),
      'type': serializer.toJson<String>(type),
      'categoryId': serializer.toJson<int?>(categoryId),
      'amount': serializer.toJson<double>(amount),
      'period': serializer.toJson<String>(period),
      'startDay': serializer.toJson<int>(startDay),
      'enabled': serializer.toJson<bool>(enabled),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
    };
  }

  Budget copyWith(
          {int? id,
          Value<String?> syncId = const Value.absent(),
          int? ledgerId,
          String? type,
          Value<int?> categoryId = const Value.absent(),
          double? amount,
          String? period,
          int? startDay,
          bool? enabled,
          DateTime? createdAt,
          DateTime? updatedAt}) =>
      Budget(
        id: id ?? this.id,
        syncId: syncId.present ? syncId.value : this.syncId,
        ledgerId: ledgerId ?? this.ledgerId,
        type: type ?? this.type,
        categoryId: categoryId.present ? categoryId.value : this.categoryId,
        amount: amount ?? this.amount,
        period: period ?? this.period,
        startDay: startDay ?? this.startDay,
        enabled: enabled ?? this.enabled,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );
  Budget copyWithCompanion(BudgetsCompanion data) {
    return Budget(
      id: data.id.present ? data.id.value : this.id,
      syncId: data.syncId.present ? data.syncId.value : this.syncId,
      ledgerId: data.ledgerId.present ? data.ledgerId.value : this.ledgerId,
      type: data.type.present ? data.type.value : this.type,
      categoryId:
          data.categoryId.present ? data.categoryId.value : this.categoryId,
      amount: data.amount.present ? data.amount.value : this.amount,
      period: data.period.present ? data.period.value : this.period,
      startDay: data.startDay.present ? data.startDay.value : this.startDay,
      enabled: data.enabled.present ? data.enabled.value : this.enabled,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Budget(')
          ..write('id: $id, ')
          ..write('syncId: $syncId, ')
          ..write('ledgerId: $ledgerId, ')
          ..write('type: $type, ')
          ..write('categoryId: $categoryId, ')
          ..write('amount: $amount, ')
          ..write('period: $period, ')
          ..write('startDay: $startDay, ')
          ..write('enabled: $enabled, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, syncId, ledgerId, type, categoryId,
      amount, period, startDay, enabled, createdAt, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Budget &&
          other.id == this.id &&
          other.syncId == this.syncId &&
          other.ledgerId == this.ledgerId &&
          other.type == this.type &&
          other.categoryId == this.categoryId &&
          other.amount == this.amount &&
          other.period == this.period &&
          other.startDay == this.startDay &&
          other.enabled == this.enabled &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class BudgetsCompanion extends UpdateCompanion<Budget> {
  final Value<int> id;
  final Value<String?> syncId;
  final Value<int> ledgerId;
  final Value<String> type;
  final Value<int?> categoryId;
  final Value<double> amount;
  final Value<String> period;
  final Value<int> startDay;
  final Value<bool> enabled;
  final Value<DateTime> createdAt;
  final Value<DateTime> updatedAt;
  const BudgetsCompanion({
    this.id = const Value.absent(),
    this.syncId = const Value.absent(),
    this.ledgerId = const Value.absent(),
    this.type = const Value.absent(),
    this.categoryId = const Value.absent(),
    this.amount = const Value.absent(),
    this.period = const Value.absent(),
    this.startDay = const Value.absent(),
    this.enabled = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
  });
  BudgetsCompanion.insert({
    this.id = const Value.absent(),
    this.syncId = const Value.absent(),
    required int ledgerId,
    this.type = const Value.absent(),
    this.categoryId = const Value.absent(),
    required double amount,
    this.period = const Value.absent(),
    this.startDay = const Value.absent(),
    this.enabled = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
  })  : ledgerId = Value(ledgerId),
        amount = Value(amount);
  static Insertable<Budget> custom({
    Expression<int>? id,
    Expression<String>? syncId,
    Expression<int>? ledgerId,
    Expression<String>? type,
    Expression<int>? categoryId,
    Expression<double>? amount,
    Expression<String>? period,
    Expression<int>? startDay,
    Expression<bool>? enabled,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? updatedAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (syncId != null) 'sync_id': syncId,
      if (ledgerId != null) 'ledger_id': ledgerId,
      if (type != null) 'type': type,
      if (categoryId != null) 'category_id': categoryId,
      if (amount != null) 'amount': amount,
      if (period != null) 'period': period,
      if (startDay != null) 'start_day': startDay,
      if (enabled != null) 'enabled': enabled,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
    });
  }

  BudgetsCompanion copyWith(
      {Value<int>? id,
      Value<String?>? syncId,
      Value<int>? ledgerId,
      Value<String>? type,
      Value<int?>? categoryId,
      Value<double>? amount,
      Value<String>? period,
      Value<int>? startDay,
      Value<bool>? enabled,
      Value<DateTime>? createdAt,
      Value<DateTime>? updatedAt}) {
    return BudgetsCompanion(
      id: id ?? this.id,
      syncId: syncId ?? this.syncId,
      ledgerId: ledgerId ?? this.ledgerId,
      type: type ?? this.type,
      categoryId: categoryId ?? this.categoryId,
      amount: amount ?? this.amount,
      period: period ?? this.period,
      startDay: startDay ?? this.startDay,
      enabled: enabled ?? this.enabled,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (syncId.present) {
      map['sync_id'] = Variable<String>(syncId.value);
    }
    if (ledgerId.present) {
      map['ledger_id'] = Variable<int>(ledgerId.value);
    }
    if (type.present) {
      map['type'] = Variable<String>(type.value);
    }
    if (categoryId.present) {
      map['category_id'] = Variable<int>(categoryId.value);
    }
    if (amount.present) {
      map['amount'] = Variable<double>(amount.value);
    }
    if (period.present) {
      map['period'] = Variable<String>(period.value);
    }
    if (startDay.present) {
      map['start_day'] = Variable<int>(startDay.value);
    }
    if (enabled.present) {
      map['enabled'] = Variable<bool>(enabled.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('BudgetsCompanion(')
          ..write('id: $id, ')
          ..write('syncId: $syncId, ')
          ..write('ledgerId: $ledgerId, ')
          ..write('type: $type, ')
          ..write('categoryId: $categoryId, ')
          ..write('amount: $amount, ')
          ..write('period: $period, ')
          ..write('startDay: $startDay, ')
          ..write('enabled: $enabled, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }
}

class $SavingsGoalsTable extends SavingsGoals
    with TableInfo<$SavingsGoalsTable, SavingsGoal> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SavingsGoalsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _syncIdMeta = const VerificationMeta('syncId');
  @override
  late final GeneratedColumn<String> syncId = GeneratedColumn<String>(
      'sync_id', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _ledgerIdMeta =
      const VerificationMeta('ledgerId');
  @override
  late final GeneratedColumn<int> ledgerId = GeneratedColumn<int>(
      'ledger_id', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
      'name', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _targetAmountMeta =
      const VerificationMeta('targetAmount');
  @override
  late final GeneratedColumn<double> targetAmount = GeneratedColumn<double>(
      'target_amount', aliasedName, false,
      type: DriftSqlType.double, requiredDuringInsert: true);
  static const VerificationMeta _currencyMeta =
      const VerificationMeta('currency');
  @override
  late final GeneratedColumn<String> currency = GeneratedColumn<String>(
      'currency', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('CNY'));
  static const VerificationMeta _accountIdMeta =
      const VerificationMeta('accountId');
  @override
  late final GeneratedColumn<int> accountId = GeneratedColumn<int>(
      'account_id', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _savedAmountMeta =
      const VerificationMeta('savedAmount');
  @override
  late final GeneratedColumn<double> savedAmount = GeneratedColumn<double>(
      'saved_amount', aliasedName, false,
      type: DriftSqlType.double,
      requiredDuringInsert: false,
      defaultValue: const Constant(0.0));
  static const VerificationMeta _startDateMeta =
      const VerificationMeta('startDate');
  @override
  late final GeneratedColumn<DateTime> startDate = GeneratedColumn<DateTime>(
      'start_date', aliasedName, false,
      type: DriftSqlType.dateTime,
      requiredDuringInsert: false,
      defaultValue: currentDateAndTime);
  static const VerificationMeta _targetDateMeta =
      const VerificationMeta('targetDate');
  @override
  late final GeneratedColumn<DateTime> targetDate = GeneratedColumn<DateTime>(
      'target_date', aliasedName, true,
      type: DriftSqlType.dateTime, requiredDuringInsert: false);
  static const VerificationMeta _noteMeta = const VerificationMeta('note');
  @override
  late final GeneratedColumn<String> note = GeneratedColumn<String>(
      'note', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _sortOrderMeta =
      const VerificationMeta('sortOrder');
  @override
  late final GeneratedColumn<int> sortOrder = GeneratedColumn<int>(
      'sort_order', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
      'created_at', aliasedName, false,
      type: DriftSqlType.dateTime,
      requiredDuringInsert: false,
      defaultValue: currentDateAndTime);
  static const VerificationMeta _updatedAtMeta =
      const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
      'updated_at', aliasedName, false,
      type: DriftSqlType.dateTime,
      requiredDuringInsert: false,
      defaultValue: currentDateAndTime);
  @override
  List<GeneratedColumn> get $columns => [
        id,
        syncId,
        ledgerId,
        name,
        targetAmount,
        currency,
        accountId,
        savedAmount,
        startDate,
        targetDate,
        note,
        sortOrder,
        createdAt,
        updatedAt
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'savings_goals';
  @override
  VerificationContext validateIntegrity(Insertable<SavingsGoal> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('sync_id')) {
      context.handle(_syncIdMeta,
          syncId.isAcceptableOrUnknown(data['sync_id']!, _syncIdMeta));
    }
    if (data.containsKey('ledger_id')) {
      context.handle(_ledgerIdMeta,
          ledgerId.isAcceptableOrUnknown(data['ledger_id']!, _ledgerIdMeta));
    } else if (isInserting) {
      context.missing(_ledgerIdMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
          _nameMeta, name.isAcceptableOrUnknown(data['name']!, _nameMeta));
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('target_amount')) {
      context.handle(
          _targetAmountMeta,
          targetAmount.isAcceptableOrUnknown(
              data['target_amount']!, _targetAmountMeta));
    } else if (isInserting) {
      context.missing(_targetAmountMeta);
    }
    if (data.containsKey('currency')) {
      context.handle(_currencyMeta,
          currency.isAcceptableOrUnknown(data['currency']!, _currencyMeta));
    }
    if (data.containsKey('account_id')) {
      context.handle(_accountIdMeta,
          accountId.isAcceptableOrUnknown(data['account_id']!, _accountIdMeta));
    }
    if (data.containsKey('saved_amount')) {
      context.handle(
          _savedAmountMeta,
          savedAmount.isAcceptableOrUnknown(
              data['saved_amount']!, _savedAmountMeta));
    }
    if (data.containsKey('start_date')) {
      context.handle(_startDateMeta,
          startDate.isAcceptableOrUnknown(data['start_date']!, _startDateMeta));
    }
    if (data.containsKey('target_date')) {
      context.handle(
          _targetDateMeta,
          targetDate.isAcceptableOrUnknown(
              data['target_date']!, _targetDateMeta));
    }
    if (data.containsKey('note')) {
      context.handle(
          _noteMeta, note.isAcceptableOrUnknown(data['note']!, _noteMeta));
    }
    if (data.containsKey('sort_order')) {
      context.handle(_sortOrderMeta,
          sortOrder.isAcceptableOrUnknown(data['sort_order']!, _sortOrderMeta));
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta,
          updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  SavingsGoal map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SavingsGoal(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      syncId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}sync_id']),
      ledgerId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}ledger_id'])!,
      name: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}name'])!,
      targetAmount: attachedDatabase.typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}target_amount'])!,
      currency: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}currency'])!,
      accountId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}account_id']),
      savedAmount: attachedDatabase.typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}saved_amount'])!,
      startDate: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}start_date'])!,
      targetDate: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}target_date']),
      note: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}note']),
      sortOrder: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}sort_order'])!,
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}created_at'])!,
      updatedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}updated_at'])!,
    );
  }

  @override
  $SavingsGoalsTable createAlias(String alias) {
    return $SavingsGoalsTable(attachedDatabase, alias);
  }
}

class SavingsGoal extends DataClass implements Insertable<SavingsGoal> {
  final int id;

  /// 跨设备同步 syncId(UUID)。新建必填,server 端按此做 entity_sync_id,
  /// 跨设备 LWW 合并(与 budgets.sync_id 同构)。
  final String? syncId;

  /// 关联账本ID。ledger-scoped 实体:变更走
  /// `ChangeTracker.recordLedgerChange` 且 ledgerId 必须 > 0,ledger_id 同时是
  /// 快照段门控(sectionAbsent)的作用域依据。
  final int ledgerId;

  /// 目标名称
  final String name;

  /// 目标金额
  final double targetAmount;

  /// 目标币种(ISO 大写)。账户模式下由 UI 强制等于关联账户币种。
  final String currency;

  /// 关联储蓄账户(账户模式)。账户被删除时**置 NULL** 降级为手动模式,
  /// 不级联删除目标(见 design.md §1.4)。
  final int? accountId;

  /// 手动累计额(仅 accountId 为空时生效)
  final double savedAmount;

  /// 起算日(速度估算基准)
  final DateTime startDate;

  /// 期望达成日(nullable,仅用于对照展示,不做校验)
  final DateTime? targetDate;

  /// 备注
  final String? note;

  /// 排序(预留,UI 本批按创建顺序展示)
  final int sortOrder;

  /// 创建时间
  final DateTime createdAt;

  /// 更新时间(由 trg_savings_goals_touch_updated_at 触发器维护)
  final DateTime updatedAt;
  const SavingsGoal(
      {required this.id,
      this.syncId,
      required this.ledgerId,
      required this.name,
      required this.targetAmount,
      required this.currency,
      this.accountId,
      required this.savedAmount,
      required this.startDate,
      this.targetDate,
      this.note,
      required this.sortOrder,
      required this.createdAt,
      required this.updatedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    if (!nullToAbsent || syncId != null) {
      map['sync_id'] = Variable<String>(syncId);
    }
    map['ledger_id'] = Variable<int>(ledgerId);
    map['name'] = Variable<String>(name);
    map['target_amount'] = Variable<double>(targetAmount);
    map['currency'] = Variable<String>(currency);
    if (!nullToAbsent || accountId != null) {
      map['account_id'] = Variable<int>(accountId);
    }
    map['saved_amount'] = Variable<double>(savedAmount);
    map['start_date'] = Variable<DateTime>(startDate);
    if (!nullToAbsent || targetDate != null) {
      map['target_date'] = Variable<DateTime>(targetDate);
    }
    if (!nullToAbsent || note != null) {
      map['note'] = Variable<String>(note);
    }
    map['sort_order'] = Variable<int>(sortOrder);
    map['created_at'] = Variable<DateTime>(createdAt);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    return map;
  }

  SavingsGoalsCompanion toCompanion(bool nullToAbsent) {
    return SavingsGoalsCompanion(
      id: Value(id),
      syncId:
          syncId == null && nullToAbsent ? const Value.absent() : Value(syncId),
      ledgerId: Value(ledgerId),
      name: Value(name),
      targetAmount: Value(targetAmount),
      currency: Value(currency),
      accountId: accountId == null && nullToAbsent
          ? const Value.absent()
          : Value(accountId),
      savedAmount: Value(savedAmount),
      startDate: Value(startDate),
      targetDate: targetDate == null && nullToAbsent
          ? const Value.absent()
          : Value(targetDate),
      note: note == null && nullToAbsent ? const Value.absent() : Value(note),
      sortOrder: Value(sortOrder),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory SavingsGoal.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SavingsGoal(
      id: serializer.fromJson<int>(json['id']),
      syncId: serializer.fromJson<String?>(json['syncId']),
      ledgerId: serializer.fromJson<int>(json['ledgerId']),
      name: serializer.fromJson<String>(json['name']),
      targetAmount: serializer.fromJson<double>(json['targetAmount']),
      currency: serializer.fromJson<String>(json['currency']),
      accountId: serializer.fromJson<int?>(json['accountId']),
      savedAmount: serializer.fromJson<double>(json['savedAmount']),
      startDate: serializer.fromJson<DateTime>(json['startDate']),
      targetDate: serializer.fromJson<DateTime?>(json['targetDate']),
      note: serializer.fromJson<String?>(json['note']),
      sortOrder: serializer.fromJson<int>(json['sortOrder']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'syncId': serializer.toJson<String?>(syncId),
      'ledgerId': serializer.toJson<int>(ledgerId),
      'name': serializer.toJson<String>(name),
      'targetAmount': serializer.toJson<double>(targetAmount),
      'currency': serializer.toJson<String>(currency),
      'accountId': serializer.toJson<int?>(accountId),
      'savedAmount': serializer.toJson<double>(savedAmount),
      'startDate': serializer.toJson<DateTime>(startDate),
      'targetDate': serializer.toJson<DateTime?>(targetDate),
      'note': serializer.toJson<String?>(note),
      'sortOrder': serializer.toJson<int>(sortOrder),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
    };
  }

  SavingsGoal copyWith(
          {int? id,
          Value<String?> syncId = const Value.absent(),
          int? ledgerId,
          String? name,
          double? targetAmount,
          String? currency,
          Value<int?> accountId = const Value.absent(),
          double? savedAmount,
          DateTime? startDate,
          Value<DateTime?> targetDate = const Value.absent(),
          Value<String?> note = const Value.absent(),
          int? sortOrder,
          DateTime? createdAt,
          DateTime? updatedAt}) =>
      SavingsGoal(
        id: id ?? this.id,
        syncId: syncId.present ? syncId.value : this.syncId,
        ledgerId: ledgerId ?? this.ledgerId,
        name: name ?? this.name,
        targetAmount: targetAmount ?? this.targetAmount,
        currency: currency ?? this.currency,
        accountId: accountId.present ? accountId.value : this.accountId,
        savedAmount: savedAmount ?? this.savedAmount,
        startDate: startDate ?? this.startDate,
        targetDate: targetDate.present ? targetDate.value : this.targetDate,
        note: note.present ? note.value : this.note,
        sortOrder: sortOrder ?? this.sortOrder,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );
  SavingsGoal copyWithCompanion(SavingsGoalsCompanion data) {
    return SavingsGoal(
      id: data.id.present ? data.id.value : this.id,
      syncId: data.syncId.present ? data.syncId.value : this.syncId,
      ledgerId: data.ledgerId.present ? data.ledgerId.value : this.ledgerId,
      name: data.name.present ? data.name.value : this.name,
      targetAmount: data.targetAmount.present
          ? data.targetAmount.value
          : this.targetAmount,
      currency: data.currency.present ? data.currency.value : this.currency,
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      savedAmount:
          data.savedAmount.present ? data.savedAmount.value : this.savedAmount,
      startDate: data.startDate.present ? data.startDate.value : this.startDate,
      targetDate:
          data.targetDate.present ? data.targetDate.value : this.targetDate,
      note: data.note.present ? data.note.value : this.note,
      sortOrder: data.sortOrder.present ? data.sortOrder.value : this.sortOrder,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SavingsGoal(')
          ..write('id: $id, ')
          ..write('syncId: $syncId, ')
          ..write('ledgerId: $ledgerId, ')
          ..write('name: $name, ')
          ..write('targetAmount: $targetAmount, ')
          ..write('currency: $currency, ')
          ..write('accountId: $accountId, ')
          ..write('savedAmount: $savedAmount, ')
          ..write('startDate: $startDate, ')
          ..write('targetDate: $targetDate, ')
          ..write('note: $note, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      id,
      syncId,
      ledgerId,
      name,
      targetAmount,
      currency,
      accountId,
      savedAmount,
      startDate,
      targetDate,
      note,
      sortOrder,
      createdAt,
      updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SavingsGoal &&
          other.id == this.id &&
          other.syncId == this.syncId &&
          other.ledgerId == this.ledgerId &&
          other.name == this.name &&
          other.targetAmount == this.targetAmount &&
          other.currency == this.currency &&
          other.accountId == this.accountId &&
          other.savedAmount == this.savedAmount &&
          other.startDate == this.startDate &&
          other.targetDate == this.targetDate &&
          other.note == this.note &&
          other.sortOrder == this.sortOrder &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class SavingsGoalsCompanion extends UpdateCompanion<SavingsGoal> {
  final Value<int> id;
  final Value<String?> syncId;
  final Value<int> ledgerId;
  final Value<String> name;
  final Value<double> targetAmount;
  final Value<String> currency;
  final Value<int?> accountId;
  final Value<double> savedAmount;
  final Value<DateTime> startDate;
  final Value<DateTime?> targetDate;
  final Value<String?> note;
  final Value<int> sortOrder;
  final Value<DateTime> createdAt;
  final Value<DateTime> updatedAt;
  const SavingsGoalsCompanion({
    this.id = const Value.absent(),
    this.syncId = const Value.absent(),
    this.ledgerId = const Value.absent(),
    this.name = const Value.absent(),
    this.targetAmount = const Value.absent(),
    this.currency = const Value.absent(),
    this.accountId = const Value.absent(),
    this.savedAmount = const Value.absent(),
    this.startDate = const Value.absent(),
    this.targetDate = const Value.absent(),
    this.note = const Value.absent(),
    this.sortOrder = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
  });
  SavingsGoalsCompanion.insert({
    this.id = const Value.absent(),
    this.syncId = const Value.absent(),
    required int ledgerId,
    required String name,
    required double targetAmount,
    this.currency = const Value.absent(),
    this.accountId = const Value.absent(),
    this.savedAmount = const Value.absent(),
    this.startDate = const Value.absent(),
    this.targetDate = const Value.absent(),
    this.note = const Value.absent(),
    this.sortOrder = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
  })  : ledgerId = Value(ledgerId),
        name = Value(name),
        targetAmount = Value(targetAmount);
  static Insertable<SavingsGoal> custom({
    Expression<int>? id,
    Expression<String>? syncId,
    Expression<int>? ledgerId,
    Expression<String>? name,
    Expression<double>? targetAmount,
    Expression<String>? currency,
    Expression<int>? accountId,
    Expression<double>? savedAmount,
    Expression<DateTime>? startDate,
    Expression<DateTime>? targetDate,
    Expression<String>? note,
    Expression<int>? sortOrder,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? updatedAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (syncId != null) 'sync_id': syncId,
      if (ledgerId != null) 'ledger_id': ledgerId,
      if (name != null) 'name': name,
      if (targetAmount != null) 'target_amount': targetAmount,
      if (currency != null) 'currency': currency,
      if (accountId != null) 'account_id': accountId,
      if (savedAmount != null) 'saved_amount': savedAmount,
      if (startDate != null) 'start_date': startDate,
      if (targetDate != null) 'target_date': targetDate,
      if (note != null) 'note': note,
      if (sortOrder != null) 'sort_order': sortOrder,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
    });
  }

  SavingsGoalsCompanion copyWith(
      {Value<int>? id,
      Value<String?>? syncId,
      Value<int>? ledgerId,
      Value<String>? name,
      Value<double>? targetAmount,
      Value<String>? currency,
      Value<int?>? accountId,
      Value<double>? savedAmount,
      Value<DateTime>? startDate,
      Value<DateTime?>? targetDate,
      Value<String?>? note,
      Value<int>? sortOrder,
      Value<DateTime>? createdAt,
      Value<DateTime>? updatedAt}) {
    return SavingsGoalsCompanion(
      id: id ?? this.id,
      syncId: syncId ?? this.syncId,
      ledgerId: ledgerId ?? this.ledgerId,
      name: name ?? this.name,
      targetAmount: targetAmount ?? this.targetAmount,
      currency: currency ?? this.currency,
      accountId: accountId ?? this.accountId,
      savedAmount: savedAmount ?? this.savedAmount,
      startDate: startDate ?? this.startDate,
      targetDate: targetDate ?? this.targetDate,
      note: note ?? this.note,
      sortOrder: sortOrder ?? this.sortOrder,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (syncId.present) {
      map['sync_id'] = Variable<String>(syncId.value);
    }
    if (ledgerId.present) {
      map['ledger_id'] = Variable<int>(ledgerId.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (targetAmount.present) {
      map['target_amount'] = Variable<double>(targetAmount.value);
    }
    if (currency.present) {
      map['currency'] = Variable<String>(currency.value);
    }
    if (accountId.present) {
      map['account_id'] = Variable<int>(accountId.value);
    }
    if (savedAmount.present) {
      map['saved_amount'] = Variable<double>(savedAmount.value);
    }
    if (startDate.present) {
      map['start_date'] = Variable<DateTime>(startDate.value);
    }
    if (targetDate.present) {
      map['target_date'] = Variable<DateTime>(targetDate.value);
    }
    if (note.present) {
      map['note'] = Variable<String>(note.value);
    }
    if (sortOrder.present) {
      map['sort_order'] = Variable<int>(sortOrder.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SavingsGoalsCompanion(')
          ..write('id: $id, ')
          ..write('syncId: $syncId, ')
          ..write('ledgerId: $ledgerId, ')
          ..write('name: $name, ')
          ..write('targetAmount: $targetAmount, ')
          ..write('currency: $currency, ')
          ..write('accountId: $accountId, ')
          ..write('savedAmount: $savedAmount, ')
          ..write('startDate: $startDate, ')
          ..write('targetDate: $targetDate, ')
          ..write('note: $note, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }
}

class $TransactionAttachmentsTable extends TransactionAttachments
    with TableInfo<$TransactionAttachmentsTable, TransactionAttachment> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $TransactionAttachmentsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _transactionIdMeta =
      const VerificationMeta('transactionId');
  @override
  late final GeneratedColumn<int> transactionId = GeneratedColumn<int>(
      'transaction_id', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _fileNameMeta =
      const VerificationMeta('fileName');
  @override
  late final GeneratedColumn<String> fileName = GeneratedColumn<String>(
      'file_name', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _originalNameMeta =
      const VerificationMeta('originalName');
  @override
  late final GeneratedColumn<String> originalName = GeneratedColumn<String>(
      'original_name', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _fileSizeMeta =
      const VerificationMeta('fileSize');
  @override
  late final GeneratedColumn<int> fileSize = GeneratedColumn<int>(
      'file_size', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _widthMeta = const VerificationMeta('width');
  @override
  late final GeneratedColumn<int> width = GeneratedColumn<int>(
      'width', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _heightMeta = const VerificationMeta('height');
  @override
  late final GeneratedColumn<int> height = GeneratedColumn<int>(
      'height', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _sortOrderMeta =
      const VerificationMeta('sortOrder');
  @override
  late final GeneratedColumn<int> sortOrder = GeneratedColumn<int>(
      'sort_order', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _cloudFileIdMeta =
      const VerificationMeta('cloudFileId');
  @override
  late final GeneratedColumn<String> cloudFileId = GeneratedColumn<String>(
      'cloud_file_id', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _cloudSha256Meta =
      const VerificationMeta('cloudSha256');
  @override
  late final GeneratedColumn<String> cloudSha256 = GeneratedColumn<String>(
      'cloud_sha256', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _localSha256Meta =
      const VerificationMeta('localSha256');
  @override
  late final GeneratedColumn<String> localSha256 = GeneratedColumn<String>(
      'local_sha256', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
      'created_at', aliasedName, false,
      type: DriftSqlType.dateTime,
      requiredDuringInsert: false,
      defaultValue: currentDateAndTime);
  @override
  List<GeneratedColumn> get $columns => [
        id,
        transactionId,
        fileName,
        originalName,
        fileSize,
        width,
        height,
        sortOrder,
        cloudFileId,
        cloudSha256,
        localSha256,
        createdAt
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'transaction_attachments';
  @override
  VerificationContext validateIntegrity(
      Insertable<TransactionAttachment> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('transaction_id')) {
      context.handle(
          _transactionIdMeta,
          transactionId.isAcceptableOrUnknown(
              data['transaction_id']!, _transactionIdMeta));
    } else if (isInserting) {
      context.missing(_transactionIdMeta);
    }
    if (data.containsKey('file_name')) {
      context.handle(_fileNameMeta,
          fileName.isAcceptableOrUnknown(data['file_name']!, _fileNameMeta));
    } else if (isInserting) {
      context.missing(_fileNameMeta);
    }
    if (data.containsKey('original_name')) {
      context.handle(
          _originalNameMeta,
          originalName.isAcceptableOrUnknown(
              data['original_name']!, _originalNameMeta));
    }
    if (data.containsKey('file_size')) {
      context.handle(_fileSizeMeta,
          fileSize.isAcceptableOrUnknown(data['file_size']!, _fileSizeMeta));
    }
    if (data.containsKey('width')) {
      context.handle(
          _widthMeta, width.isAcceptableOrUnknown(data['width']!, _widthMeta));
    }
    if (data.containsKey('height')) {
      context.handle(_heightMeta,
          height.isAcceptableOrUnknown(data['height']!, _heightMeta));
    }
    if (data.containsKey('sort_order')) {
      context.handle(_sortOrderMeta,
          sortOrder.isAcceptableOrUnknown(data['sort_order']!, _sortOrderMeta));
    }
    if (data.containsKey('cloud_file_id')) {
      context.handle(
          _cloudFileIdMeta,
          cloudFileId.isAcceptableOrUnknown(
              data['cloud_file_id']!, _cloudFileIdMeta));
    }
    if (data.containsKey('cloud_sha256')) {
      context.handle(
          _cloudSha256Meta,
          cloudSha256.isAcceptableOrUnknown(
              data['cloud_sha256']!, _cloudSha256Meta));
    }
    if (data.containsKey('local_sha256')) {
      context.handle(
          _localSha256Meta,
          localSha256.isAcceptableOrUnknown(
              data['local_sha256']!, _localSha256Meta));
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  TransactionAttachment map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return TransactionAttachment(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      transactionId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}transaction_id'])!,
      fileName: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}file_name'])!,
      originalName: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}original_name']),
      fileSize: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}file_size']),
      width: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}width']),
      height: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}height']),
      sortOrder: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}sort_order'])!,
      cloudFileId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}cloud_file_id']),
      cloudSha256: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}cloud_sha256']),
      localSha256: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}local_sha256']),
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}created_at'])!,
    );
  }

  @override
  $TransactionAttachmentsTable createAlias(String alias) {
    return $TransactionAttachmentsTable(attachedDatabase, alias);
  }
}

class TransactionAttachment extends DataClass
    implements Insertable<TransactionAttachment> {
  final int id;
  final int transactionId;
  final String fileName;
  final String? originalName;
  final int? fileSize;
  final int? width;
  final int? height;
  final int sortOrder;
  final String? cloudFileId;
  final String? cloudSha256;

  /// 本地文件内容 SHA256(hex)。v34 新增(attachment_binary_sync):
  /// 快照链路按内容寻址上传 `attachments/<sha256>.bin`,此列是清单锚点。
  /// 不复用 cloudSha256 —— 那是 Cloud server 回填的引用,两条链路混用会
  /// 互相污染。写入时机:saveAttachment 计算文件名时同步落列;
  /// 存量行由启动后台任务 backfillLocalSha256 分批补齐。
  final String? localSha256;
  final DateTime createdAt;
  const TransactionAttachment(
      {required this.id,
      required this.transactionId,
      required this.fileName,
      this.originalName,
      this.fileSize,
      this.width,
      this.height,
      required this.sortOrder,
      this.cloudFileId,
      this.cloudSha256,
      this.localSha256,
      required this.createdAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['transaction_id'] = Variable<int>(transactionId);
    map['file_name'] = Variable<String>(fileName);
    if (!nullToAbsent || originalName != null) {
      map['original_name'] = Variable<String>(originalName);
    }
    if (!nullToAbsent || fileSize != null) {
      map['file_size'] = Variable<int>(fileSize);
    }
    if (!nullToAbsent || width != null) {
      map['width'] = Variable<int>(width);
    }
    if (!nullToAbsent || height != null) {
      map['height'] = Variable<int>(height);
    }
    map['sort_order'] = Variable<int>(sortOrder);
    if (!nullToAbsent || cloudFileId != null) {
      map['cloud_file_id'] = Variable<String>(cloudFileId);
    }
    if (!nullToAbsent || cloudSha256 != null) {
      map['cloud_sha256'] = Variable<String>(cloudSha256);
    }
    if (!nullToAbsent || localSha256 != null) {
      map['local_sha256'] = Variable<String>(localSha256);
    }
    map['created_at'] = Variable<DateTime>(createdAt);
    return map;
  }

  TransactionAttachmentsCompanion toCompanion(bool nullToAbsent) {
    return TransactionAttachmentsCompanion(
      id: Value(id),
      transactionId: Value(transactionId),
      fileName: Value(fileName),
      originalName: originalName == null && nullToAbsent
          ? const Value.absent()
          : Value(originalName),
      fileSize: fileSize == null && nullToAbsent
          ? const Value.absent()
          : Value(fileSize),
      width:
          width == null && nullToAbsent ? const Value.absent() : Value(width),
      height:
          height == null && nullToAbsent ? const Value.absent() : Value(height),
      sortOrder: Value(sortOrder),
      cloudFileId: cloudFileId == null && nullToAbsent
          ? const Value.absent()
          : Value(cloudFileId),
      cloudSha256: cloudSha256 == null && nullToAbsent
          ? const Value.absent()
          : Value(cloudSha256),
      localSha256: localSha256 == null && nullToAbsent
          ? const Value.absent()
          : Value(localSha256),
      createdAt: Value(createdAt),
    );
  }

  factory TransactionAttachment.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return TransactionAttachment(
      id: serializer.fromJson<int>(json['id']),
      transactionId: serializer.fromJson<int>(json['transactionId']),
      fileName: serializer.fromJson<String>(json['fileName']),
      originalName: serializer.fromJson<String?>(json['originalName']),
      fileSize: serializer.fromJson<int?>(json['fileSize']),
      width: serializer.fromJson<int?>(json['width']),
      height: serializer.fromJson<int?>(json['height']),
      sortOrder: serializer.fromJson<int>(json['sortOrder']),
      cloudFileId: serializer.fromJson<String?>(json['cloudFileId']),
      cloudSha256: serializer.fromJson<String?>(json['cloudSha256']),
      localSha256: serializer.fromJson<String?>(json['localSha256']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'transactionId': serializer.toJson<int>(transactionId),
      'fileName': serializer.toJson<String>(fileName),
      'originalName': serializer.toJson<String?>(originalName),
      'fileSize': serializer.toJson<int?>(fileSize),
      'width': serializer.toJson<int?>(width),
      'height': serializer.toJson<int?>(height),
      'sortOrder': serializer.toJson<int>(sortOrder),
      'cloudFileId': serializer.toJson<String?>(cloudFileId),
      'cloudSha256': serializer.toJson<String?>(cloudSha256),
      'localSha256': serializer.toJson<String?>(localSha256),
      'createdAt': serializer.toJson<DateTime>(createdAt),
    };
  }

  TransactionAttachment copyWith(
          {int? id,
          int? transactionId,
          String? fileName,
          Value<String?> originalName = const Value.absent(),
          Value<int?> fileSize = const Value.absent(),
          Value<int?> width = const Value.absent(),
          Value<int?> height = const Value.absent(),
          int? sortOrder,
          Value<String?> cloudFileId = const Value.absent(),
          Value<String?> cloudSha256 = const Value.absent(),
          Value<String?> localSha256 = const Value.absent(),
          DateTime? createdAt}) =>
      TransactionAttachment(
        id: id ?? this.id,
        transactionId: transactionId ?? this.transactionId,
        fileName: fileName ?? this.fileName,
        originalName:
            originalName.present ? originalName.value : this.originalName,
        fileSize: fileSize.present ? fileSize.value : this.fileSize,
        width: width.present ? width.value : this.width,
        height: height.present ? height.value : this.height,
        sortOrder: sortOrder ?? this.sortOrder,
        cloudFileId: cloudFileId.present ? cloudFileId.value : this.cloudFileId,
        cloudSha256: cloudSha256.present ? cloudSha256.value : this.cloudSha256,
        localSha256: localSha256.present ? localSha256.value : this.localSha256,
        createdAt: createdAt ?? this.createdAt,
      );
  TransactionAttachment copyWithCompanion(
      TransactionAttachmentsCompanion data) {
    return TransactionAttachment(
      id: data.id.present ? data.id.value : this.id,
      transactionId: data.transactionId.present
          ? data.transactionId.value
          : this.transactionId,
      fileName: data.fileName.present ? data.fileName.value : this.fileName,
      originalName: data.originalName.present
          ? data.originalName.value
          : this.originalName,
      fileSize: data.fileSize.present ? data.fileSize.value : this.fileSize,
      width: data.width.present ? data.width.value : this.width,
      height: data.height.present ? data.height.value : this.height,
      sortOrder: data.sortOrder.present ? data.sortOrder.value : this.sortOrder,
      cloudFileId:
          data.cloudFileId.present ? data.cloudFileId.value : this.cloudFileId,
      cloudSha256:
          data.cloudSha256.present ? data.cloudSha256.value : this.cloudSha256,
      localSha256:
          data.localSha256.present ? data.localSha256.value : this.localSha256,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('TransactionAttachment(')
          ..write('id: $id, ')
          ..write('transactionId: $transactionId, ')
          ..write('fileName: $fileName, ')
          ..write('originalName: $originalName, ')
          ..write('fileSize: $fileSize, ')
          ..write('width: $width, ')
          ..write('height: $height, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('cloudFileId: $cloudFileId, ')
          ..write('cloudSha256: $cloudSha256, ')
          ..write('localSha256: $localSha256, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      id,
      transactionId,
      fileName,
      originalName,
      fileSize,
      width,
      height,
      sortOrder,
      cloudFileId,
      cloudSha256,
      localSha256,
      createdAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TransactionAttachment &&
          other.id == this.id &&
          other.transactionId == this.transactionId &&
          other.fileName == this.fileName &&
          other.originalName == this.originalName &&
          other.fileSize == this.fileSize &&
          other.width == this.width &&
          other.height == this.height &&
          other.sortOrder == this.sortOrder &&
          other.cloudFileId == this.cloudFileId &&
          other.cloudSha256 == this.cloudSha256 &&
          other.localSha256 == this.localSha256 &&
          other.createdAt == this.createdAt);
}

class TransactionAttachmentsCompanion
    extends UpdateCompanion<TransactionAttachment> {
  final Value<int> id;
  final Value<int> transactionId;
  final Value<String> fileName;
  final Value<String?> originalName;
  final Value<int?> fileSize;
  final Value<int?> width;
  final Value<int?> height;
  final Value<int> sortOrder;
  final Value<String?> cloudFileId;
  final Value<String?> cloudSha256;
  final Value<String?> localSha256;
  final Value<DateTime> createdAt;
  const TransactionAttachmentsCompanion({
    this.id = const Value.absent(),
    this.transactionId = const Value.absent(),
    this.fileName = const Value.absent(),
    this.originalName = const Value.absent(),
    this.fileSize = const Value.absent(),
    this.width = const Value.absent(),
    this.height = const Value.absent(),
    this.sortOrder = const Value.absent(),
    this.cloudFileId = const Value.absent(),
    this.cloudSha256 = const Value.absent(),
    this.localSha256 = const Value.absent(),
    this.createdAt = const Value.absent(),
  });
  TransactionAttachmentsCompanion.insert({
    this.id = const Value.absent(),
    required int transactionId,
    required String fileName,
    this.originalName = const Value.absent(),
    this.fileSize = const Value.absent(),
    this.width = const Value.absent(),
    this.height = const Value.absent(),
    this.sortOrder = const Value.absent(),
    this.cloudFileId = const Value.absent(),
    this.cloudSha256 = const Value.absent(),
    this.localSha256 = const Value.absent(),
    this.createdAt = const Value.absent(),
  })  : transactionId = Value(transactionId),
        fileName = Value(fileName);
  static Insertable<TransactionAttachment> custom({
    Expression<int>? id,
    Expression<int>? transactionId,
    Expression<String>? fileName,
    Expression<String>? originalName,
    Expression<int>? fileSize,
    Expression<int>? width,
    Expression<int>? height,
    Expression<int>? sortOrder,
    Expression<String>? cloudFileId,
    Expression<String>? cloudSha256,
    Expression<String>? localSha256,
    Expression<DateTime>? createdAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (transactionId != null) 'transaction_id': transactionId,
      if (fileName != null) 'file_name': fileName,
      if (originalName != null) 'original_name': originalName,
      if (fileSize != null) 'file_size': fileSize,
      if (width != null) 'width': width,
      if (height != null) 'height': height,
      if (sortOrder != null) 'sort_order': sortOrder,
      if (cloudFileId != null) 'cloud_file_id': cloudFileId,
      if (cloudSha256 != null) 'cloud_sha256': cloudSha256,
      if (localSha256 != null) 'local_sha256': localSha256,
      if (createdAt != null) 'created_at': createdAt,
    });
  }

  TransactionAttachmentsCompanion copyWith(
      {Value<int>? id,
      Value<int>? transactionId,
      Value<String>? fileName,
      Value<String?>? originalName,
      Value<int?>? fileSize,
      Value<int?>? width,
      Value<int?>? height,
      Value<int>? sortOrder,
      Value<String?>? cloudFileId,
      Value<String?>? cloudSha256,
      Value<String?>? localSha256,
      Value<DateTime>? createdAt}) {
    return TransactionAttachmentsCompanion(
      id: id ?? this.id,
      transactionId: transactionId ?? this.transactionId,
      fileName: fileName ?? this.fileName,
      originalName: originalName ?? this.originalName,
      fileSize: fileSize ?? this.fileSize,
      width: width ?? this.width,
      height: height ?? this.height,
      sortOrder: sortOrder ?? this.sortOrder,
      cloudFileId: cloudFileId ?? this.cloudFileId,
      cloudSha256: cloudSha256 ?? this.cloudSha256,
      localSha256: localSha256 ?? this.localSha256,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (transactionId.present) {
      map['transaction_id'] = Variable<int>(transactionId.value);
    }
    if (fileName.present) {
      map['file_name'] = Variable<String>(fileName.value);
    }
    if (originalName.present) {
      map['original_name'] = Variable<String>(originalName.value);
    }
    if (fileSize.present) {
      map['file_size'] = Variable<int>(fileSize.value);
    }
    if (width.present) {
      map['width'] = Variable<int>(width.value);
    }
    if (height.present) {
      map['height'] = Variable<int>(height.value);
    }
    if (sortOrder.present) {
      map['sort_order'] = Variable<int>(sortOrder.value);
    }
    if (cloudFileId.present) {
      map['cloud_file_id'] = Variable<String>(cloudFileId.value);
    }
    if (cloudSha256.present) {
      map['cloud_sha256'] = Variable<String>(cloudSha256.value);
    }
    if (localSha256.present) {
      map['local_sha256'] = Variable<String>(localSha256.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('TransactionAttachmentsCompanion(')
          ..write('id: $id, ')
          ..write('transactionId: $transactionId, ')
          ..write('fileName: $fileName, ')
          ..write('originalName: $originalName, ')
          ..write('fileSize: $fileSize, ')
          ..write('width: $width, ')
          ..write('height: $height, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('cloudFileId: $cloudFileId, ')
          ..write('cloudSha256: $cloudSha256, ')
          ..write('localSha256: $localSha256, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }
}

class $LocalChangesTable extends LocalChanges
    with TableInfo<$LocalChangesTable, LocalChange> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalChangesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _entityTypeMeta =
      const VerificationMeta('entityType');
  @override
  late final GeneratedColumn<String> entityType = GeneratedColumn<String>(
      'entity_type', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _entityIdMeta =
      const VerificationMeta('entityId');
  @override
  late final GeneratedColumn<int> entityId = GeneratedColumn<int>(
      'entity_id', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _entitySyncIdMeta =
      const VerificationMeta('entitySyncId');
  @override
  late final GeneratedColumn<String> entitySyncId = GeneratedColumn<String>(
      'entity_sync_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _ledgerIdMeta =
      const VerificationMeta('ledgerId');
  @override
  late final GeneratedColumn<int> ledgerId = GeneratedColumn<int>(
      'ledger_id', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _actionMeta = const VerificationMeta('action');
  @override
  late final GeneratedColumn<String> action = GeneratedColumn<String>(
      'action', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _payloadJsonMeta =
      const VerificationMeta('payloadJson');
  @override
  late final GeneratedColumn<String> payloadJson = GeneratedColumn<String>(
      'payload_json', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
      'created_at', aliasedName, false,
      type: DriftSqlType.dateTime,
      requiredDuringInsert: false,
      defaultValue: currentDateAndTime);
  static const VerificationMeta _pushedAtMeta =
      const VerificationMeta('pushedAt');
  @override
  late final GeneratedColumn<DateTime> pushedAt = GeneratedColumn<DateTime>(
      'pushed_at', aliasedName, true,
      type: DriftSqlType.dateTime, requiredDuringInsert: false);
  @override
  List<GeneratedColumn> get $columns => [
        id,
        entityType,
        entityId,
        entitySyncId,
        ledgerId,
        action,
        payloadJson,
        createdAt,
        pushedAt
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'local_changes';
  @override
  VerificationContext validateIntegrity(Insertable<LocalChange> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('entity_type')) {
      context.handle(
          _entityTypeMeta,
          entityType.isAcceptableOrUnknown(
              data['entity_type']!, _entityTypeMeta));
    } else if (isInserting) {
      context.missing(_entityTypeMeta);
    }
    if (data.containsKey('entity_id')) {
      context.handle(_entityIdMeta,
          entityId.isAcceptableOrUnknown(data['entity_id']!, _entityIdMeta));
    } else if (isInserting) {
      context.missing(_entityIdMeta);
    }
    if (data.containsKey('entity_sync_id')) {
      context.handle(
          _entitySyncIdMeta,
          entitySyncId.isAcceptableOrUnknown(
              data['entity_sync_id']!, _entitySyncIdMeta));
    } else if (isInserting) {
      context.missing(_entitySyncIdMeta);
    }
    if (data.containsKey('ledger_id')) {
      context.handle(_ledgerIdMeta,
          ledgerId.isAcceptableOrUnknown(data['ledger_id']!, _ledgerIdMeta));
    } else if (isInserting) {
      context.missing(_ledgerIdMeta);
    }
    if (data.containsKey('action')) {
      context.handle(_actionMeta,
          action.isAcceptableOrUnknown(data['action']!, _actionMeta));
    } else if (isInserting) {
      context.missing(_actionMeta);
    }
    if (data.containsKey('payload_json')) {
      context.handle(
          _payloadJsonMeta,
          payloadJson.isAcceptableOrUnknown(
              data['payload_json']!, _payloadJsonMeta));
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    }
    if (data.containsKey('pushed_at')) {
      context.handle(_pushedAtMeta,
          pushedAt.isAcceptableOrUnknown(data['pushed_at']!, _pushedAtMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  LocalChange map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LocalChange(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      entityType: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}entity_type'])!,
      entityId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}entity_id'])!,
      entitySyncId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}entity_sync_id'])!,
      ledgerId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}ledger_id'])!,
      action: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}action'])!,
      payloadJson: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}payload_json']),
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}created_at'])!,
      pushedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}pushed_at']),
    );
  }

  @override
  $LocalChangesTable createAlias(String alias) {
    return $LocalChangesTable(attachedDatabase, alias);
  }
}

class LocalChange extends DataClass implements Insertable<LocalChange> {
  final int id;
  final String entityType;
  final int entityId;
  final String entitySyncId;
  final int ledgerId;
  final String action;
  final String? payloadJson;
  final DateTime createdAt;
  final DateTime? pushedAt;
  const LocalChange(
      {required this.id,
      required this.entityType,
      required this.entityId,
      required this.entitySyncId,
      required this.ledgerId,
      required this.action,
      this.payloadJson,
      required this.createdAt,
      this.pushedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['entity_type'] = Variable<String>(entityType);
    map['entity_id'] = Variable<int>(entityId);
    map['entity_sync_id'] = Variable<String>(entitySyncId);
    map['ledger_id'] = Variable<int>(ledgerId);
    map['action'] = Variable<String>(action);
    if (!nullToAbsent || payloadJson != null) {
      map['payload_json'] = Variable<String>(payloadJson);
    }
    map['created_at'] = Variable<DateTime>(createdAt);
    if (!nullToAbsent || pushedAt != null) {
      map['pushed_at'] = Variable<DateTime>(pushedAt);
    }
    return map;
  }

  LocalChangesCompanion toCompanion(bool nullToAbsent) {
    return LocalChangesCompanion(
      id: Value(id),
      entityType: Value(entityType),
      entityId: Value(entityId),
      entitySyncId: Value(entitySyncId),
      ledgerId: Value(ledgerId),
      action: Value(action),
      payloadJson: payloadJson == null && nullToAbsent
          ? const Value.absent()
          : Value(payloadJson),
      createdAt: Value(createdAt),
      pushedAt: pushedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(pushedAt),
    );
  }

  factory LocalChange.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LocalChange(
      id: serializer.fromJson<int>(json['id']),
      entityType: serializer.fromJson<String>(json['entityType']),
      entityId: serializer.fromJson<int>(json['entityId']),
      entitySyncId: serializer.fromJson<String>(json['entitySyncId']),
      ledgerId: serializer.fromJson<int>(json['ledgerId']),
      action: serializer.fromJson<String>(json['action']),
      payloadJson: serializer.fromJson<String?>(json['payloadJson']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      pushedAt: serializer.fromJson<DateTime?>(json['pushedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'entityType': serializer.toJson<String>(entityType),
      'entityId': serializer.toJson<int>(entityId),
      'entitySyncId': serializer.toJson<String>(entitySyncId),
      'ledgerId': serializer.toJson<int>(ledgerId),
      'action': serializer.toJson<String>(action),
      'payloadJson': serializer.toJson<String?>(payloadJson),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'pushedAt': serializer.toJson<DateTime?>(pushedAt),
    };
  }

  LocalChange copyWith(
          {int? id,
          String? entityType,
          int? entityId,
          String? entitySyncId,
          int? ledgerId,
          String? action,
          Value<String?> payloadJson = const Value.absent(),
          DateTime? createdAt,
          Value<DateTime?> pushedAt = const Value.absent()}) =>
      LocalChange(
        id: id ?? this.id,
        entityType: entityType ?? this.entityType,
        entityId: entityId ?? this.entityId,
        entitySyncId: entitySyncId ?? this.entitySyncId,
        ledgerId: ledgerId ?? this.ledgerId,
        action: action ?? this.action,
        payloadJson: payloadJson.present ? payloadJson.value : this.payloadJson,
        createdAt: createdAt ?? this.createdAt,
        pushedAt: pushedAt.present ? pushedAt.value : this.pushedAt,
      );
  LocalChange copyWithCompanion(LocalChangesCompanion data) {
    return LocalChange(
      id: data.id.present ? data.id.value : this.id,
      entityType:
          data.entityType.present ? data.entityType.value : this.entityType,
      entityId: data.entityId.present ? data.entityId.value : this.entityId,
      entitySyncId: data.entitySyncId.present
          ? data.entitySyncId.value
          : this.entitySyncId,
      ledgerId: data.ledgerId.present ? data.ledgerId.value : this.ledgerId,
      action: data.action.present ? data.action.value : this.action,
      payloadJson:
          data.payloadJson.present ? data.payloadJson.value : this.payloadJson,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      pushedAt: data.pushedAt.present ? data.pushedAt.value : this.pushedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LocalChange(')
          ..write('id: $id, ')
          ..write('entityType: $entityType, ')
          ..write('entityId: $entityId, ')
          ..write('entitySyncId: $entitySyncId, ')
          ..write('ledgerId: $ledgerId, ')
          ..write('action: $action, ')
          ..write('payloadJson: $payloadJson, ')
          ..write('createdAt: $createdAt, ')
          ..write('pushedAt: $pushedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, entityType, entityId, entitySyncId,
      ledgerId, action, payloadJson, createdAt, pushedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LocalChange &&
          other.id == this.id &&
          other.entityType == this.entityType &&
          other.entityId == this.entityId &&
          other.entitySyncId == this.entitySyncId &&
          other.ledgerId == this.ledgerId &&
          other.action == this.action &&
          other.payloadJson == this.payloadJson &&
          other.createdAt == this.createdAt &&
          other.pushedAt == this.pushedAt);
}

class LocalChangesCompanion extends UpdateCompanion<LocalChange> {
  final Value<int> id;
  final Value<String> entityType;
  final Value<int> entityId;
  final Value<String> entitySyncId;
  final Value<int> ledgerId;
  final Value<String> action;
  final Value<String?> payloadJson;
  final Value<DateTime> createdAt;
  final Value<DateTime?> pushedAt;
  const LocalChangesCompanion({
    this.id = const Value.absent(),
    this.entityType = const Value.absent(),
    this.entityId = const Value.absent(),
    this.entitySyncId = const Value.absent(),
    this.ledgerId = const Value.absent(),
    this.action = const Value.absent(),
    this.payloadJson = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.pushedAt = const Value.absent(),
  });
  LocalChangesCompanion.insert({
    this.id = const Value.absent(),
    required String entityType,
    required int entityId,
    required String entitySyncId,
    required int ledgerId,
    required String action,
    this.payloadJson = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.pushedAt = const Value.absent(),
  })  : entityType = Value(entityType),
        entityId = Value(entityId),
        entitySyncId = Value(entitySyncId),
        ledgerId = Value(ledgerId),
        action = Value(action);
  static Insertable<LocalChange> custom({
    Expression<int>? id,
    Expression<String>? entityType,
    Expression<int>? entityId,
    Expression<String>? entitySyncId,
    Expression<int>? ledgerId,
    Expression<String>? action,
    Expression<String>? payloadJson,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? pushedAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (entityType != null) 'entity_type': entityType,
      if (entityId != null) 'entity_id': entityId,
      if (entitySyncId != null) 'entity_sync_id': entitySyncId,
      if (ledgerId != null) 'ledger_id': ledgerId,
      if (action != null) 'action': action,
      if (payloadJson != null) 'payload_json': payloadJson,
      if (createdAt != null) 'created_at': createdAt,
      if (pushedAt != null) 'pushed_at': pushedAt,
    });
  }

  LocalChangesCompanion copyWith(
      {Value<int>? id,
      Value<String>? entityType,
      Value<int>? entityId,
      Value<String>? entitySyncId,
      Value<int>? ledgerId,
      Value<String>? action,
      Value<String?>? payloadJson,
      Value<DateTime>? createdAt,
      Value<DateTime?>? pushedAt}) {
    return LocalChangesCompanion(
      id: id ?? this.id,
      entityType: entityType ?? this.entityType,
      entityId: entityId ?? this.entityId,
      entitySyncId: entitySyncId ?? this.entitySyncId,
      ledgerId: ledgerId ?? this.ledgerId,
      action: action ?? this.action,
      payloadJson: payloadJson ?? this.payloadJson,
      createdAt: createdAt ?? this.createdAt,
      pushedAt: pushedAt ?? this.pushedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (entityType.present) {
      map['entity_type'] = Variable<String>(entityType.value);
    }
    if (entityId.present) {
      map['entity_id'] = Variable<int>(entityId.value);
    }
    if (entitySyncId.present) {
      map['entity_sync_id'] = Variable<String>(entitySyncId.value);
    }
    if (ledgerId.present) {
      map['ledger_id'] = Variable<int>(ledgerId.value);
    }
    if (action.present) {
      map['action'] = Variable<String>(action.value);
    }
    if (payloadJson.present) {
      map['payload_json'] = Variable<String>(payloadJson.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (pushedAt.present) {
      map['pushed_at'] = Variable<DateTime>(pushedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalChangesCompanion(')
          ..write('id: $id, ')
          ..write('entityType: $entityType, ')
          ..write('entityId: $entityId, ')
          ..write('entitySyncId: $entitySyncId, ')
          ..write('ledgerId: $ledgerId, ')
          ..write('action: $action, ')
          ..write('payloadJson: $payloadJson, ')
          ..write('createdAt: $createdAt, ')
          ..write('pushedAt: $pushedAt')
          ..write(')'))
        .toString();
  }
}

class $SyncPullErrorsTable extends SyncPullErrors
    with TableInfo<$SyncPullErrorsTable, SyncPullError> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SyncPullErrorsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _changeIdMeta =
      const VerificationMeta('changeId');
  @override
  late final GeneratedColumn<int> changeId = GeneratedColumn<int>(
      'change_id', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: true,
      defaultConstraints: GeneratedColumn.constraintIsAlways('UNIQUE'));
  static const VerificationMeta _ledgerExternalIdMeta =
      const VerificationMeta('ledgerExternalId');
  @override
  late final GeneratedColumn<String> ledgerExternalId = GeneratedColumn<String>(
      'ledger_external_id', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _entityTypeMeta =
      const VerificationMeta('entityType');
  @override
  late final GeneratedColumn<String> entityType = GeneratedColumn<String>(
      'entity_type', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _entitySyncIdMeta =
      const VerificationMeta('entitySyncId');
  @override
  late final GeneratedColumn<String> entitySyncId = GeneratedColumn<String>(
      'entity_sync_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _actionMeta = const VerificationMeta('action');
  @override
  late final GeneratedColumn<String> action = GeneratedColumn<String>(
      'action', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _rawChangeJsonMeta =
      const VerificationMeta('rawChangeJson');
  @override
  late final GeneratedColumn<String> rawChangeJson = GeneratedColumn<String>(
      'raw_change_json', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _errorClassMeta =
      const VerificationMeta('errorClass');
  @override
  late final GeneratedColumn<String> errorClass = GeneratedColumn<String>(
      'error_class', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _errorMessageMeta =
      const VerificationMeta('errorMessage');
  @override
  late final GeneratedColumn<String> errorMessage = GeneratedColumn<String>(
      'error_message', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _stackTraceMeta =
      const VerificationMeta('stackTrace');
  @override
  late final GeneratedColumn<String> stackTrace = GeneratedColumn<String>(
      'stack_trace', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _firstSeenAtMeta =
      const VerificationMeta('firstSeenAt');
  @override
  late final GeneratedColumn<DateTime> firstSeenAt = GeneratedColumn<DateTime>(
      'first_seen_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  static const VerificationMeta _lastAttemptAtMeta =
      const VerificationMeta('lastAttemptAt');
  @override
  late final GeneratedColumn<DateTime> lastAttemptAt =
      GeneratedColumn<DateTime>('last_attempt_at', aliasedName, false,
          type: DriftSqlType.dateTime, requiredDuringInsert: true);
  static const VerificationMeta _attemptCountMeta =
      const VerificationMeta('attemptCount');
  @override
  late final GeneratedColumn<int> attemptCount = GeneratedColumn<int>(
      'attempt_count', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(1));
  static const VerificationMeta _userActionMeta =
      const VerificationMeta('userAction');
  @override
  late final GeneratedColumn<String> userAction = GeneratedColumn<String>(
      'user_action', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _resolvedAtMeta =
      const VerificationMeta('resolvedAt');
  @override
  late final GeneratedColumn<DateTime> resolvedAt = GeneratedColumn<DateTime>(
      'resolved_at', aliasedName, true,
      type: DriftSqlType.dateTime, requiredDuringInsert: false);
  @override
  List<GeneratedColumn> get $columns => [
        id,
        changeId,
        ledgerExternalId,
        entityType,
        entitySyncId,
        action,
        rawChangeJson,
        errorClass,
        errorMessage,
        stackTrace,
        firstSeenAt,
        lastAttemptAt,
        attemptCount,
        userAction,
        resolvedAt
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sync_pull_errors';
  @override
  VerificationContext validateIntegrity(Insertable<SyncPullError> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('change_id')) {
      context.handle(_changeIdMeta,
          changeId.isAcceptableOrUnknown(data['change_id']!, _changeIdMeta));
    } else if (isInserting) {
      context.missing(_changeIdMeta);
    }
    if (data.containsKey('ledger_external_id')) {
      context.handle(
          _ledgerExternalIdMeta,
          ledgerExternalId.isAcceptableOrUnknown(
              data['ledger_external_id']!, _ledgerExternalIdMeta));
    }
    if (data.containsKey('entity_type')) {
      context.handle(
          _entityTypeMeta,
          entityType.isAcceptableOrUnknown(
              data['entity_type']!, _entityTypeMeta));
    } else if (isInserting) {
      context.missing(_entityTypeMeta);
    }
    if (data.containsKey('entity_sync_id')) {
      context.handle(
          _entitySyncIdMeta,
          entitySyncId.isAcceptableOrUnknown(
              data['entity_sync_id']!, _entitySyncIdMeta));
    } else if (isInserting) {
      context.missing(_entitySyncIdMeta);
    }
    if (data.containsKey('action')) {
      context.handle(_actionMeta,
          action.isAcceptableOrUnknown(data['action']!, _actionMeta));
    } else if (isInserting) {
      context.missing(_actionMeta);
    }
    if (data.containsKey('raw_change_json')) {
      context.handle(
          _rawChangeJsonMeta,
          rawChangeJson.isAcceptableOrUnknown(
              data['raw_change_json']!, _rawChangeJsonMeta));
    } else if (isInserting) {
      context.missing(_rawChangeJsonMeta);
    }
    if (data.containsKey('error_class')) {
      context.handle(
          _errorClassMeta,
          errorClass.isAcceptableOrUnknown(
              data['error_class']!, _errorClassMeta));
    }
    if (data.containsKey('error_message')) {
      context.handle(
          _errorMessageMeta,
          errorMessage.isAcceptableOrUnknown(
              data['error_message']!, _errorMessageMeta));
    }
    if (data.containsKey('stack_trace')) {
      context.handle(
          _stackTraceMeta,
          stackTrace.isAcceptableOrUnknown(
              data['stack_trace']!, _stackTraceMeta));
    }
    if (data.containsKey('first_seen_at')) {
      context.handle(
          _firstSeenAtMeta,
          firstSeenAt.isAcceptableOrUnknown(
              data['first_seen_at']!, _firstSeenAtMeta));
    } else if (isInserting) {
      context.missing(_firstSeenAtMeta);
    }
    if (data.containsKey('last_attempt_at')) {
      context.handle(
          _lastAttemptAtMeta,
          lastAttemptAt.isAcceptableOrUnknown(
              data['last_attempt_at']!, _lastAttemptAtMeta));
    } else if (isInserting) {
      context.missing(_lastAttemptAtMeta);
    }
    if (data.containsKey('attempt_count')) {
      context.handle(
          _attemptCountMeta,
          attemptCount.isAcceptableOrUnknown(
              data['attempt_count']!, _attemptCountMeta));
    }
    if (data.containsKey('user_action')) {
      context.handle(
          _userActionMeta,
          userAction.isAcceptableOrUnknown(
              data['user_action']!, _userActionMeta));
    }
    if (data.containsKey('resolved_at')) {
      context.handle(
          _resolvedAtMeta,
          resolvedAt.isAcceptableOrUnknown(
              data['resolved_at']!, _resolvedAtMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  SyncPullError map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SyncPullError(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      changeId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}change_id'])!,
      ledgerExternalId: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}ledger_external_id']),
      entityType: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}entity_type'])!,
      entitySyncId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}entity_sync_id'])!,
      action: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}action'])!,
      rawChangeJson: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}raw_change_json'])!,
      errorClass: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}error_class']),
      errorMessage: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}error_message']),
      stackTrace: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}stack_trace']),
      firstSeenAt: attachedDatabase.typeMapping.read(
          DriftSqlType.dateTime, data['${effectivePrefix}first_seen_at'])!,
      lastAttemptAt: attachedDatabase.typeMapping.read(
          DriftSqlType.dateTime, data['${effectivePrefix}last_attempt_at'])!,
      attemptCount: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}attempt_count'])!,
      userAction: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}user_action']),
      resolvedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}resolved_at']),
    );
  }

  @override
  $SyncPullErrorsTable createAlias(String alias) {
    return $SyncPullErrorsTable(attachedDatabase, alias);
  }
}

class SyncPullError extends DataClass implements Insertable<SyncPullError> {
  final int id;
  final int changeId;
  final String? ledgerExternalId;
  final String entityType;
  final String entitySyncId;
  final String action;
  final String rawChangeJson;
  final String? errorClass;
  final String? errorMessage;
  final String? stackTrace;
  final DateTime firstSeenAt;
  final DateTime lastAttemptAt;
  final int attemptCount;
  final String? userAction;
  final DateTime? resolvedAt;
  const SyncPullError(
      {required this.id,
      required this.changeId,
      this.ledgerExternalId,
      required this.entityType,
      required this.entitySyncId,
      required this.action,
      required this.rawChangeJson,
      this.errorClass,
      this.errorMessage,
      this.stackTrace,
      required this.firstSeenAt,
      required this.lastAttemptAt,
      required this.attemptCount,
      this.userAction,
      this.resolvedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['change_id'] = Variable<int>(changeId);
    if (!nullToAbsent || ledgerExternalId != null) {
      map['ledger_external_id'] = Variable<String>(ledgerExternalId);
    }
    map['entity_type'] = Variable<String>(entityType);
    map['entity_sync_id'] = Variable<String>(entitySyncId);
    map['action'] = Variable<String>(action);
    map['raw_change_json'] = Variable<String>(rawChangeJson);
    if (!nullToAbsent || errorClass != null) {
      map['error_class'] = Variable<String>(errorClass);
    }
    if (!nullToAbsent || errorMessage != null) {
      map['error_message'] = Variable<String>(errorMessage);
    }
    if (!nullToAbsent || stackTrace != null) {
      map['stack_trace'] = Variable<String>(stackTrace);
    }
    map['first_seen_at'] = Variable<DateTime>(firstSeenAt);
    map['last_attempt_at'] = Variable<DateTime>(lastAttemptAt);
    map['attempt_count'] = Variable<int>(attemptCount);
    if (!nullToAbsent || userAction != null) {
      map['user_action'] = Variable<String>(userAction);
    }
    if (!nullToAbsent || resolvedAt != null) {
      map['resolved_at'] = Variable<DateTime>(resolvedAt);
    }
    return map;
  }

  SyncPullErrorsCompanion toCompanion(bool nullToAbsent) {
    return SyncPullErrorsCompanion(
      id: Value(id),
      changeId: Value(changeId),
      ledgerExternalId: ledgerExternalId == null && nullToAbsent
          ? const Value.absent()
          : Value(ledgerExternalId),
      entityType: Value(entityType),
      entitySyncId: Value(entitySyncId),
      action: Value(action),
      rawChangeJson: Value(rawChangeJson),
      errorClass: errorClass == null && nullToAbsent
          ? const Value.absent()
          : Value(errorClass),
      errorMessage: errorMessage == null && nullToAbsent
          ? const Value.absent()
          : Value(errorMessage),
      stackTrace: stackTrace == null && nullToAbsent
          ? const Value.absent()
          : Value(stackTrace),
      firstSeenAt: Value(firstSeenAt),
      lastAttemptAt: Value(lastAttemptAt),
      attemptCount: Value(attemptCount),
      userAction: userAction == null && nullToAbsent
          ? const Value.absent()
          : Value(userAction),
      resolvedAt: resolvedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(resolvedAt),
    );
  }

  factory SyncPullError.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SyncPullError(
      id: serializer.fromJson<int>(json['id']),
      changeId: serializer.fromJson<int>(json['changeId']),
      ledgerExternalId: serializer.fromJson<String?>(json['ledgerExternalId']),
      entityType: serializer.fromJson<String>(json['entityType']),
      entitySyncId: serializer.fromJson<String>(json['entitySyncId']),
      action: serializer.fromJson<String>(json['action']),
      rawChangeJson: serializer.fromJson<String>(json['rawChangeJson']),
      errorClass: serializer.fromJson<String?>(json['errorClass']),
      errorMessage: serializer.fromJson<String?>(json['errorMessage']),
      stackTrace: serializer.fromJson<String?>(json['stackTrace']),
      firstSeenAt: serializer.fromJson<DateTime>(json['firstSeenAt']),
      lastAttemptAt: serializer.fromJson<DateTime>(json['lastAttemptAt']),
      attemptCount: serializer.fromJson<int>(json['attemptCount']),
      userAction: serializer.fromJson<String?>(json['userAction']),
      resolvedAt: serializer.fromJson<DateTime?>(json['resolvedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'changeId': serializer.toJson<int>(changeId),
      'ledgerExternalId': serializer.toJson<String?>(ledgerExternalId),
      'entityType': serializer.toJson<String>(entityType),
      'entitySyncId': serializer.toJson<String>(entitySyncId),
      'action': serializer.toJson<String>(action),
      'rawChangeJson': serializer.toJson<String>(rawChangeJson),
      'errorClass': serializer.toJson<String?>(errorClass),
      'errorMessage': serializer.toJson<String?>(errorMessage),
      'stackTrace': serializer.toJson<String?>(stackTrace),
      'firstSeenAt': serializer.toJson<DateTime>(firstSeenAt),
      'lastAttemptAt': serializer.toJson<DateTime>(lastAttemptAt),
      'attemptCount': serializer.toJson<int>(attemptCount),
      'userAction': serializer.toJson<String?>(userAction),
      'resolvedAt': serializer.toJson<DateTime?>(resolvedAt),
    };
  }

  SyncPullError copyWith(
          {int? id,
          int? changeId,
          Value<String?> ledgerExternalId = const Value.absent(),
          String? entityType,
          String? entitySyncId,
          String? action,
          String? rawChangeJson,
          Value<String?> errorClass = const Value.absent(),
          Value<String?> errorMessage = const Value.absent(),
          Value<String?> stackTrace = const Value.absent(),
          DateTime? firstSeenAt,
          DateTime? lastAttemptAt,
          int? attemptCount,
          Value<String?> userAction = const Value.absent(),
          Value<DateTime?> resolvedAt = const Value.absent()}) =>
      SyncPullError(
        id: id ?? this.id,
        changeId: changeId ?? this.changeId,
        ledgerExternalId: ledgerExternalId.present
            ? ledgerExternalId.value
            : this.ledgerExternalId,
        entityType: entityType ?? this.entityType,
        entitySyncId: entitySyncId ?? this.entitySyncId,
        action: action ?? this.action,
        rawChangeJson: rawChangeJson ?? this.rawChangeJson,
        errorClass: errorClass.present ? errorClass.value : this.errorClass,
        errorMessage:
            errorMessage.present ? errorMessage.value : this.errorMessage,
        stackTrace: stackTrace.present ? stackTrace.value : this.stackTrace,
        firstSeenAt: firstSeenAt ?? this.firstSeenAt,
        lastAttemptAt: lastAttemptAt ?? this.lastAttemptAt,
        attemptCount: attemptCount ?? this.attemptCount,
        userAction: userAction.present ? userAction.value : this.userAction,
        resolvedAt: resolvedAt.present ? resolvedAt.value : this.resolvedAt,
      );
  SyncPullError copyWithCompanion(SyncPullErrorsCompanion data) {
    return SyncPullError(
      id: data.id.present ? data.id.value : this.id,
      changeId: data.changeId.present ? data.changeId.value : this.changeId,
      ledgerExternalId: data.ledgerExternalId.present
          ? data.ledgerExternalId.value
          : this.ledgerExternalId,
      entityType:
          data.entityType.present ? data.entityType.value : this.entityType,
      entitySyncId: data.entitySyncId.present
          ? data.entitySyncId.value
          : this.entitySyncId,
      action: data.action.present ? data.action.value : this.action,
      rawChangeJson: data.rawChangeJson.present
          ? data.rawChangeJson.value
          : this.rawChangeJson,
      errorClass:
          data.errorClass.present ? data.errorClass.value : this.errorClass,
      errorMessage: data.errorMessage.present
          ? data.errorMessage.value
          : this.errorMessage,
      stackTrace:
          data.stackTrace.present ? data.stackTrace.value : this.stackTrace,
      firstSeenAt:
          data.firstSeenAt.present ? data.firstSeenAt.value : this.firstSeenAt,
      lastAttemptAt: data.lastAttemptAt.present
          ? data.lastAttemptAt.value
          : this.lastAttemptAt,
      attemptCount: data.attemptCount.present
          ? data.attemptCount.value
          : this.attemptCount,
      userAction:
          data.userAction.present ? data.userAction.value : this.userAction,
      resolvedAt:
          data.resolvedAt.present ? data.resolvedAt.value : this.resolvedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SyncPullError(')
          ..write('id: $id, ')
          ..write('changeId: $changeId, ')
          ..write('ledgerExternalId: $ledgerExternalId, ')
          ..write('entityType: $entityType, ')
          ..write('entitySyncId: $entitySyncId, ')
          ..write('action: $action, ')
          ..write('rawChangeJson: $rawChangeJson, ')
          ..write('errorClass: $errorClass, ')
          ..write('errorMessage: $errorMessage, ')
          ..write('stackTrace: $stackTrace, ')
          ..write('firstSeenAt: $firstSeenAt, ')
          ..write('lastAttemptAt: $lastAttemptAt, ')
          ..write('attemptCount: $attemptCount, ')
          ..write('userAction: $userAction, ')
          ..write('resolvedAt: $resolvedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      id,
      changeId,
      ledgerExternalId,
      entityType,
      entitySyncId,
      action,
      rawChangeJson,
      errorClass,
      errorMessage,
      stackTrace,
      firstSeenAt,
      lastAttemptAt,
      attemptCount,
      userAction,
      resolvedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SyncPullError &&
          other.id == this.id &&
          other.changeId == this.changeId &&
          other.ledgerExternalId == this.ledgerExternalId &&
          other.entityType == this.entityType &&
          other.entitySyncId == this.entitySyncId &&
          other.action == this.action &&
          other.rawChangeJson == this.rawChangeJson &&
          other.errorClass == this.errorClass &&
          other.errorMessage == this.errorMessage &&
          other.stackTrace == this.stackTrace &&
          other.firstSeenAt == this.firstSeenAt &&
          other.lastAttemptAt == this.lastAttemptAt &&
          other.attemptCount == this.attemptCount &&
          other.userAction == this.userAction &&
          other.resolvedAt == this.resolvedAt);
}

class SyncPullErrorsCompanion extends UpdateCompanion<SyncPullError> {
  final Value<int> id;
  final Value<int> changeId;
  final Value<String?> ledgerExternalId;
  final Value<String> entityType;
  final Value<String> entitySyncId;
  final Value<String> action;
  final Value<String> rawChangeJson;
  final Value<String?> errorClass;
  final Value<String?> errorMessage;
  final Value<String?> stackTrace;
  final Value<DateTime> firstSeenAt;
  final Value<DateTime> lastAttemptAt;
  final Value<int> attemptCount;
  final Value<String?> userAction;
  final Value<DateTime?> resolvedAt;
  const SyncPullErrorsCompanion({
    this.id = const Value.absent(),
    this.changeId = const Value.absent(),
    this.ledgerExternalId = const Value.absent(),
    this.entityType = const Value.absent(),
    this.entitySyncId = const Value.absent(),
    this.action = const Value.absent(),
    this.rawChangeJson = const Value.absent(),
    this.errorClass = const Value.absent(),
    this.errorMessage = const Value.absent(),
    this.stackTrace = const Value.absent(),
    this.firstSeenAt = const Value.absent(),
    this.lastAttemptAt = const Value.absent(),
    this.attemptCount = const Value.absent(),
    this.userAction = const Value.absent(),
    this.resolvedAt = const Value.absent(),
  });
  SyncPullErrorsCompanion.insert({
    this.id = const Value.absent(),
    required int changeId,
    this.ledgerExternalId = const Value.absent(),
    required String entityType,
    required String entitySyncId,
    required String action,
    required String rawChangeJson,
    this.errorClass = const Value.absent(),
    this.errorMessage = const Value.absent(),
    this.stackTrace = const Value.absent(),
    required DateTime firstSeenAt,
    required DateTime lastAttemptAt,
    this.attemptCount = const Value.absent(),
    this.userAction = const Value.absent(),
    this.resolvedAt = const Value.absent(),
  })  : changeId = Value(changeId),
        entityType = Value(entityType),
        entitySyncId = Value(entitySyncId),
        action = Value(action),
        rawChangeJson = Value(rawChangeJson),
        firstSeenAt = Value(firstSeenAt),
        lastAttemptAt = Value(lastAttemptAt);
  static Insertable<SyncPullError> custom({
    Expression<int>? id,
    Expression<int>? changeId,
    Expression<String>? ledgerExternalId,
    Expression<String>? entityType,
    Expression<String>? entitySyncId,
    Expression<String>? action,
    Expression<String>? rawChangeJson,
    Expression<String>? errorClass,
    Expression<String>? errorMessage,
    Expression<String>? stackTrace,
    Expression<DateTime>? firstSeenAt,
    Expression<DateTime>? lastAttemptAt,
    Expression<int>? attemptCount,
    Expression<String>? userAction,
    Expression<DateTime>? resolvedAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (changeId != null) 'change_id': changeId,
      if (ledgerExternalId != null) 'ledger_external_id': ledgerExternalId,
      if (entityType != null) 'entity_type': entityType,
      if (entitySyncId != null) 'entity_sync_id': entitySyncId,
      if (action != null) 'action': action,
      if (rawChangeJson != null) 'raw_change_json': rawChangeJson,
      if (errorClass != null) 'error_class': errorClass,
      if (errorMessage != null) 'error_message': errorMessage,
      if (stackTrace != null) 'stack_trace': stackTrace,
      if (firstSeenAt != null) 'first_seen_at': firstSeenAt,
      if (lastAttemptAt != null) 'last_attempt_at': lastAttemptAt,
      if (attemptCount != null) 'attempt_count': attemptCount,
      if (userAction != null) 'user_action': userAction,
      if (resolvedAt != null) 'resolved_at': resolvedAt,
    });
  }

  SyncPullErrorsCompanion copyWith(
      {Value<int>? id,
      Value<int>? changeId,
      Value<String?>? ledgerExternalId,
      Value<String>? entityType,
      Value<String>? entitySyncId,
      Value<String>? action,
      Value<String>? rawChangeJson,
      Value<String?>? errorClass,
      Value<String?>? errorMessage,
      Value<String?>? stackTrace,
      Value<DateTime>? firstSeenAt,
      Value<DateTime>? lastAttemptAt,
      Value<int>? attemptCount,
      Value<String?>? userAction,
      Value<DateTime?>? resolvedAt}) {
    return SyncPullErrorsCompanion(
      id: id ?? this.id,
      changeId: changeId ?? this.changeId,
      ledgerExternalId: ledgerExternalId ?? this.ledgerExternalId,
      entityType: entityType ?? this.entityType,
      entitySyncId: entitySyncId ?? this.entitySyncId,
      action: action ?? this.action,
      rawChangeJson: rawChangeJson ?? this.rawChangeJson,
      errorClass: errorClass ?? this.errorClass,
      errorMessage: errorMessage ?? this.errorMessage,
      stackTrace: stackTrace ?? this.stackTrace,
      firstSeenAt: firstSeenAt ?? this.firstSeenAt,
      lastAttemptAt: lastAttemptAt ?? this.lastAttemptAt,
      attemptCount: attemptCount ?? this.attemptCount,
      userAction: userAction ?? this.userAction,
      resolvedAt: resolvedAt ?? this.resolvedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (changeId.present) {
      map['change_id'] = Variable<int>(changeId.value);
    }
    if (ledgerExternalId.present) {
      map['ledger_external_id'] = Variable<String>(ledgerExternalId.value);
    }
    if (entityType.present) {
      map['entity_type'] = Variable<String>(entityType.value);
    }
    if (entitySyncId.present) {
      map['entity_sync_id'] = Variable<String>(entitySyncId.value);
    }
    if (action.present) {
      map['action'] = Variable<String>(action.value);
    }
    if (rawChangeJson.present) {
      map['raw_change_json'] = Variable<String>(rawChangeJson.value);
    }
    if (errorClass.present) {
      map['error_class'] = Variable<String>(errorClass.value);
    }
    if (errorMessage.present) {
      map['error_message'] = Variable<String>(errorMessage.value);
    }
    if (stackTrace.present) {
      map['stack_trace'] = Variable<String>(stackTrace.value);
    }
    if (firstSeenAt.present) {
      map['first_seen_at'] = Variable<DateTime>(firstSeenAt.value);
    }
    if (lastAttemptAt.present) {
      map['last_attempt_at'] = Variable<DateTime>(lastAttemptAt.value);
    }
    if (attemptCount.present) {
      map['attempt_count'] = Variable<int>(attemptCount.value);
    }
    if (userAction.present) {
      map['user_action'] = Variable<String>(userAction.value);
    }
    if (resolvedAt.present) {
      map['resolved_at'] = Variable<DateTime>(resolvedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SyncPullErrorsCompanion(')
          ..write('id: $id, ')
          ..write('changeId: $changeId, ')
          ..write('ledgerExternalId: $ledgerExternalId, ')
          ..write('entityType: $entityType, ')
          ..write('entitySyncId: $entitySyncId, ')
          ..write('action: $action, ')
          ..write('rawChangeJson: $rawChangeJson, ')
          ..write('errorClass: $errorClass, ')
          ..write('errorMessage: $errorMessage, ')
          ..write('stackTrace: $stackTrace, ')
          ..write('firstSeenAt: $firstSeenAt, ')
          ..write('lastAttemptAt: $lastAttemptAt, ')
          ..write('attemptCount: $attemptCount, ')
          ..write('userAction: $userAction, ')
          ..write('resolvedAt: $resolvedAt')
          ..write(')'))
        .toString();
  }
}

class $ExchangeRatesTable extends ExchangeRates
    with TableInfo<$ExchangeRatesTable, ExchangeRate> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ExchangeRatesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _baseCurrencyMeta =
      const VerificationMeta('baseCurrency');
  @override
  late final GeneratedColumn<String> baseCurrency = GeneratedColumn<String>(
      'base_currency', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _quoteCurrencyMeta =
      const VerificationMeta('quoteCurrency');
  @override
  late final GeneratedColumn<String> quoteCurrency = GeneratedColumn<String>(
      'quote_currency', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _rateDateMeta =
      const VerificationMeta('rateDate');
  @override
  late final GeneratedColumn<String> rateDate = GeneratedColumn<String>(
      'rate_date', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _rateMeta = const VerificationMeta('rate');
  @override
  late final GeneratedColumn<String> rate = GeneratedColumn<String>(
      'rate', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _sourceMeta = const VerificationMeta('source');
  @override
  late final GeneratedColumn<String> source = GeneratedColumn<String>(
      'source', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _fetchedAtMeta =
      const VerificationMeta('fetchedAt');
  @override
  late final GeneratedColumn<DateTime> fetchedAt = GeneratedColumn<DateTime>(
      'fetched_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns =>
      [baseCurrency, quoteCurrency, rateDate, rate, source, fetchedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'exchange_rates';
  @override
  VerificationContext validateIntegrity(Insertable<ExchangeRate> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('base_currency')) {
      context.handle(
          _baseCurrencyMeta,
          baseCurrency.isAcceptableOrUnknown(
              data['base_currency']!, _baseCurrencyMeta));
    } else if (isInserting) {
      context.missing(_baseCurrencyMeta);
    }
    if (data.containsKey('quote_currency')) {
      context.handle(
          _quoteCurrencyMeta,
          quoteCurrency.isAcceptableOrUnknown(
              data['quote_currency']!, _quoteCurrencyMeta));
    } else if (isInserting) {
      context.missing(_quoteCurrencyMeta);
    }
    if (data.containsKey('rate_date')) {
      context.handle(_rateDateMeta,
          rateDate.isAcceptableOrUnknown(data['rate_date']!, _rateDateMeta));
    } else if (isInserting) {
      context.missing(_rateDateMeta);
    }
    if (data.containsKey('rate')) {
      context.handle(
          _rateMeta, rate.isAcceptableOrUnknown(data['rate']!, _rateMeta));
    } else if (isInserting) {
      context.missing(_rateMeta);
    }
    if (data.containsKey('source')) {
      context.handle(_sourceMeta,
          source.isAcceptableOrUnknown(data['source']!, _sourceMeta));
    } else if (isInserting) {
      context.missing(_sourceMeta);
    }
    if (data.containsKey('fetched_at')) {
      context.handle(_fetchedAtMeta,
          fetchedAt.isAcceptableOrUnknown(data['fetched_at']!, _fetchedAtMeta));
    } else if (isInserting) {
      context.missing(_fetchedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey =>
      {baseCurrency, quoteCurrency, rateDate};
  @override
  ExchangeRate map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ExchangeRate(
      baseCurrency: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}base_currency'])!,
      quoteCurrency: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}quote_currency'])!,
      rateDate: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}rate_date'])!,
      rate: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}rate'])!,
      source: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}source'])!,
      fetchedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}fetched_at'])!,
    );
  }

  @override
  $ExchangeRatesTable createAlias(String alias) {
    return $ExchangeRatesTable(attachedDatabase, alias);
  }
}

class ExchangeRate extends DataClass implements Insertable<ExchangeRate> {
  final String baseCurrency;
  final String quoteCurrency;
  final String rateDate;
  final String rate;
  final String source;
  final DateTime fetchedAt;
  const ExchangeRate(
      {required this.baseCurrency,
      required this.quoteCurrency,
      required this.rateDate,
      required this.rate,
      required this.source,
      required this.fetchedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['base_currency'] = Variable<String>(baseCurrency);
    map['quote_currency'] = Variable<String>(quoteCurrency);
    map['rate_date'] = Variable<String>(rateDate);
    map['rate'] = Variable<String>(rate);
    map['source'] = Variable<String>(source);
    map['fetched_at'] = Variable<DateTime>(fetchedAt);
    return map;
  }

  ExchangeRatesCompanion toCompanion(bool nullToAbsent) {
    return ExchangeRatesCompanion(
      baseCurrency: Value(baseCurrency),
      quoteCurrency: Value(quoteCurrency),
      rateDate: Value(rateDate),
      rate: Value(rate),
      source: Value(source),
      fetchedAt: Value(fetchedAt),
    );
  }

  factory ExchangeRate.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ExchangeRate(
      baseCurrency: serializer.fromJson<String>(json['baseCurrency']),
      quoteCurrency: serializer.fromJson<String>(json['quoteCurrency']),
      rateDate: serializer.fromJson<String>(json['rateDate']),
      rate: serializer.fromJson<String>(json['rate']),
      source: serializer.fromJson<String>(json['source']),
      fetchedAt: serializer.fromJson<DateTime>(json['fetchedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'baseCurrency': serializer.toJson<String>(baseCurrency),
      'quoteCurrency': serializer.toJson<String>(quoteCurrency),
      'rateDate': serializer.toJson<String>(rateDate),
      'rate': serializer.toJson<String>(rate),
      'source': serializer.toJson<String>(source),
      'fetchedAt': serializer.toJson<DateTime>(fetchedAt),
    };
  }

  ExchangeRate copyWith(
          {String? baseCurrency,
          String? quoteCurrency,
          String? rateDate,
          String? rate,
          String? source,
          DateTime? fetchedAt}) =>
      ExchangeRate(
        baseCurrency: baseCurrency ?? this.baseCurrency,
        quoteCurrency: quoteCurrency ?? this.quoteCurrency,
        rateDate: rateDate ?? this.rateDate,
        rate: rate ?? this.rate,
        source: source ?? this.source,
        fetchedAt: fetchedAt ?? this.fetchedAt,
      );
  ExchangeRate copyWithCompanion(ExchangeRatesCompanion data) {
    return ExchangeRate(
      baseCurrency: data.baseCurrency.present
          ? data.baseCurrency.value
          : this.baseCurrency,
      quoteCurrency: data.quoteCurrency.present
          ? data.quoteCurrency.value
          : this.quoteCurrency,
      rateDate: data.rateDate.present ? data.rateDate.value : this.rateDate,
      rate: data.rate.present ? data.rate.value : this.rate,
      source: data.source.present ? data.source.value : this.source,
      fetchedAt: data.fetchedAt.present ? data.fetchedAt.value : this.fetchedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ExchangeRate(')
          ..write('baseCurrency: $baseCurrency, ')
          ..write('quoteCurrency: $quoteCurrency, ')
          ..write('rateDate: $rateDate, ')
          ..write('rate: $rate, ')
          ..write('source: $source, ')
          ..write('fetchedAt: $fetchedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      baseCurrency, quoteCurrency, rateDate, rate, source, fetchedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ExchangeRate &&
          other.baseCurrency == this.baseCurrency &&
          other.quoteCurrency == this.quoteCurrency &&
          other.rateDate == this.rateDate &&
          other.rate == this.rate &&
          other.source == this.source &&
          other.fetchedAt == this.fetchedAt);
}

class ExchangeRatesCompanion extends UpdateCompanion<ExchangeRate> {
  final Value<String> baseCurrency;
  final Value<String> quoteCurrency;
  final Value<String> rateDate;
  final Value<String> rate;
  final Value<String> source;
  final Value<DateTime> fetchedAt;
  final Value<int> rowid;
  const ExchangeRatesCompanion({
    this.baseCurrency = const Value.absent(),
    this.quoteCurrency = const Value.absent(),
    this.rateDate = const Value.absent(),
    this.rate = const Value.absent(),
    this.source = const Value.absent(),
    this.fetchedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ExchangeRatesCompanion.insert({
    required String baseCurrency,
    required String quoteCurrency,
    required String rateDate,
    required String rate,
    required String source,
    required DateTime fetchedAt,
    this.rowid = const Value.absent(),
  })  : baseCurrency = Value(baseCurrency),
        quoteCurrency = Value(quoteCurrency),
        rateDate = Value(rateDate),
        rate = Value(rate),
        source = Value(source),
        fetchedAt = Value(fetchedAt);
  static Insertable<ExchangeRate> custom({
    Expression<String>? baseCurrency,
    Expression<String>? quoteCurrency,
    Expression<String>? rateDate,
    Expression<String>? rate,
    Expression<String>? source,
    Expression<DateTime>? fetchedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (baseCurrency != null) 'base_currency': baseCurrency,
      if (quoteCurrency != null) 'quote_currency': quoteCurrency,
      if (rateDate != null) 'rate_date': rateDate,
      if (rate != null) 'rate': rate,
      if (source != null) 'source': source,
      if (fetchedAt != null) 'fetched_at': fetchedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ExchangeRatesCompanion copyWith(
      {Value<String>? baseCurrency,
      Value<String>? quoteCurrency,
      Value<String>? rateDate,
      Value<String>? rate,
      Value<String>? source,
      Value<DateTime>? fetchedAt,
      Value<int>? rowid}) {
    return ExchangeRatesCompanion(
      baseCurrency: baseCurrency ?? this.baseCurrency,
      quoteCurrency: quoteCurrency ?? this.quoteCurrency,
      rateDate: rateDate ?? this.rateDate,
      rate: rate ?? this.rate,
      source: source ?? this.source,
      fetchedAt: fetchedAt ?? this.fetchedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (baseCurrency.present) {
      map['base_currency'] = Variable<String>(baseCurrency.value);
    }
    if (quoteCurrency.present) {
      map['quote_currency'] = Variable<String>(quoteCurrency.value);
    }
    if (rateDate.present) {
      map['rate_date'] = Variable<String>(rateDate.value);
    }
    if (rate.present) {
      map['rate'] = Variable<String>(rate.value);
    }
    if (source.present) {
      map['source'] = Variable<String>(source.value);
    }
    if (fetchedAt.present) {
      map['fetched_at'] = Variable<DateTime>(fetchedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ExchangeRatesCompanion(')
          ..write('baseCurrency: $baseCurrency, ')
          ..write('quoteCurrency: $quoteCurrency, ')
          ..write('rateDate: $rateDate, ')
          ..write('rate: $rate, ')
          ..write('source: $source, ')
          ..write('fetchedAt: $fetchedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ExchangeRateOverridesTable extends ExchangeRateOverrides
    with TableInfo<$ExchangeRateOverridesTable, ExchangeRateOverride> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ExchangeRateOverridesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _syncIdMeta = const VerificationMeta('syncId');
  @override
  late final GeneratedColumn<String> syncId = GeneratedColumn<String>(
      'sync_id', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _baseCurrencyMeta =
      const VerificationMeta('baseCurrency');
  @override
  late final GeneratedColumn<String> baseCurrency = GeneratedColumn<String>(
      'base_currency', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _quoteCurrencyMeta =
      const VerificationMeta('quoteCurrency');
  @override
  late final GeneratedColumn<String> quoteCurrency = GeneratedColumn<String>(
      'quote_currency', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _rateMeta = const VerificationMeta('rate');
  @override
  late final GeneratedColumn<String> rate = GeneratedColumn<String>(
      'rate', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _updatedAtMeta =
      const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
      'updated_at', aliasedName, true,
      type: DriftSqlType.dateTime, requiredDuringInsert: false);
  @override
  List<GeneratedColumn> get $columns =>
      [id, syncId, baseCurrency, quoteCurrency, rate, updatedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'exchange_rate_overrides';
  @override
  VerificationContext validateIntegrity(
      Insertable<ExchangeRateOverride> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('sync_id')) {
      context.handle(_syncIdMeta,
          syncId.isAcceptableOrUnknown(data['sync_id']!, _syncIdMeta));
    }
    if (data.containsKey('base_currency')) {
      context.handle(
          _baseCurrencyMeta,
          baseCurrency.isAcceptableOrUnknown(
              data['base_currency']!, _baseCurrencyMeta));
    } else if (isInserting) {
      context.missing(_baseCurrencyMeta);
    }
    if (data.containsKey('quote_currency')) {
      context.handle(
          _quoteCurrencyMeta,
          quoteCurrency.isAcceptableOrUnknown(
              data['quote_currency']!, _quoteCurrencyMeta));
    } else if (isInserting) {
      context.missing(_quoteCurrencyMeta);
    }
    if (data.containsKey('rate')) {
      context.handle(
          _rateMeta, rate.isAcceptableOrUnknown(data['rate']!, _rateMeta));
    } else if (isInserting) {
      context.missing(_rateMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta,
          updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  ExchangeRateOverride map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ExchangeRateOverride(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      syncId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}sync_id']),
      baseCurrency: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}base_currency'])!,
      quoteCurrency: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}quote_currency'])!,
      rate: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}rate'])!,
      updatedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}updated_at']),
    );
  }

  @override
  $ExchangeRateOverridesTable createAlias(String alias) {
    return $ExchangeRateOverridesTable(attachedDatabase, alias);
  }
}

class ExchangeRateOverride extends DataClass
    implements Insertable<ExchangeRateOverride> {
  final int id;
  final String? syncId;
  final String baseCurrency;
  final String quoteCurrency;
  final String rate;
  final DateTime? updatedAt;
  const ExchangeRateOverride(
      {required this.id,
      this.syncId,
      required this.baseCurrency,
      required this.quoteCurrency,
      required this.rate,
      this.updatedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    if (!nullToAbsent || syncId != null) {
      map['sync_id'] = Variable<String>(syncId);
    }
    map['base_currency'] = Variable<String>(baseCurrency);
    map['quote_currency'] = Variable<String>(quoteCurrency);
    map['rate'] = Variable<String>(rate);
    if (!nullToAbsent || updatedAt != null) {
      map['updated_at'] = Variable<DateTime>(updatedAt);
    }
    return map;
  }

  ExchangeRateOverridesCompanion toCompanion(bool nullToAbsent) {
    return ExchangeRateOverridesCompanion(
      id: Value(id),
      syncId:
          syncId == null && nullToAbsent ? const Value.absent() : Value(syncId),
      baseCurrency: Value(baseCurrency),
      quoteCurrency: Value(quoteCurrency),
      rate: Value(rate),
      updatedAt: updatedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(updatedAt),
    );
  }

  factory ExchangeRateOverride.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ExchangeRateOverride(
      id: serializer.fromJson<int>(json['id']),
      syncId: serializer.fromJson<String?>(json['syncId']),
      baseCurrency: serializer.fromJson<String>(json['baseCurrency']),
      quoteCurrency: serializer.fromJson<String>(json['quoteCurrency']),
      rate: serializer.fromJson<String>(json['rate']),
      updatedAt: serializer.fromJson<DateTime?>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'syncId': serializer.toJson<String?>(syncId),
      'baseCurrency': serializer.toJson<String>(baseCurrency),
      'quoteCurrency': serializer.toJson<String>(quoteCurrency),
      'rate': serializer.toJson<String>(rate),
      'updatedAt': serializer.toJson<DateTime?>(updatedAt),
    };
  }

  ExchangeRateOverride copyWith(
          {int? id,
          Value<String?> syncId = const Value.absent(),
          String? baseCurrency,
          String? quoteCurrency,
          String? rate,
          Value<DateTime?> updatedAt = const Value.absent()}) =>
      ExchangeRateOverride(
        id: id ?? this.id,
        syncId: syncId.present ? syncId.value : this.syncId,
        baseCurrency: baseCurrency ?? this.baseCurrency,
        quoteCurrency: quoteCurrency ?? this.quoteCurrency,
        rate: rate ?? this.rate,
        updatedAt: updatedAt.present ? updatedAt.value : this.updatedAt,
      );
  ExchangeRateOverride copyWithCompanion(ExchangeRateOverridesCompanion data) {
    return ExchangeRateOverride(
      id: data.id.present ? data.id.value : this.id,
      syncId: data.syncId.present ? data.syncId.value : this.syncId,
      baseCurrency: data.baseCurrency.present
          ? data.baseCurrency.value
          : this.baseCurrency,
      quoteCurrency: data.quoteCurrency.present
          ? data.quoteCurrency.value
          : this.quoteCurrency,
      rate: data.rate.present ? data.rate.value : this.rate,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ExchangeRateOverride(')
          ..write('id: $id, ')
          ..write('syncId: $syncId, ')
          ..write('baseCurrency: $baseCurrency, ')
          ..write('quoteCurrency: $quoteCurrency, ')
          ..write('rate: $rate, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, syncId, baseCurrency, quoteCurrency, rate, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ExchangeRateOverride &&
          other.id == this.id &&
          other.syncId == this.syncId &&
          other.baseCurrency == this.baseCurrency &&
          other.quoteCurrency == this.quoteCurrency &&
          other.rate == this.rate &&
          other.updatedAt == this.updatedAt);
}

class ExchangeRateOverridesCompanion
    extends UpdateCompanion<ExchangeRateOverride> {
  final Value<int> id;
  final Value<String?> syncId;
  final Value<String> baseCurrency;
  final Value<String> quoteCurrency;
  final Value<String> rate;
  final Value<DateTime?> updatedAt;
  const ExchangeRateOverridesCompanion({
    this.id = const Value.absent(),
    this.syncId = const Value.absent(),
    this.baseCurrency = const Value.absent(),
    this.quoteCurrency = const Value.absent(),
    this.rate = const Value.absent(),
    this.updatedAt = const Value.absent(),
  });
  ExchangeRateOverridesCompanion.insert({
    this.id = const Value.absent(),
    this.syncId = const Value.absent(),
    required String baseCurrency,
    required String quoteCurrency,
    required String rate,
    this.updatedAt = const Value.absent(),
  })  : baseCurrency = Value(baseCurrency),
        quoteCurrency = Value(quoteCurrency),
        rate = Value(rate);
  static Insertable<ExchangeRateOverride> custom({
    Expression<int>? id,
    Expression<String>? syncId,
    Expression<String>? baseCurrency,
    Expression<String>? quoteCurrency,
    Expression<String>? rate,
    Expression<DateTime>? updatedAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (syncId != null) 'sync_id': syncId,
      if (baseCurrency != null) 'base_currency': baseCurrency,
      if (quoteCurrency != null) 'quote_currency': quoteCurrency,
      if (rate != null) 'rate': rate,
      if (updatedAt != null) 'updated_at': updatedAt,
    });
  }

  ExchangeRateOverridesCompanion copyWith(
      {Value<int>? id,
      Value<String?>? syncId,
      Value<String>? baseCurrency,
      Value<String>? quoteCurrency,
      Value<String>? rate,
      Value<DateTime?>? updatedAt}) {
    return ExchangeRateOverridesCompanion(
      id: id ?? this.id,
      syncId: syncId ?? this.syncId,
      baseCurrency: baseCurrency ?? this.baseCurrency,
      quoteCurrency: quoteCurrency ?? this.quoteCurrency,
      rate: rate ?? this.rate,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (syncId.present) {
      map['sync_id'] = Variable<String>(syncId.value);
    }
    if (baseCurrency.present) {
      map['base_currency'] = Variable<String>(baseCurrency.value);
    }
    if (quoteCurrency.present) {
      map['quote_currency'] = Variable<String>(quoteCurrency.value);
    }
    if (rate.present) {
      map['rate'] = Variable<String>(rate.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ExchangeRateOverridesCompanion(')
          ..write('id: $id, ')
          ..write('syncId: $syncId, ')
          ..write('baseCurrency: $baseCurrency, ')
          ..write('quoteCurrency: $quoteCurrency, ')
          ..write('rate: $rate, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }
}

class $EntityChangeWatermarksTable extends EntityChangeWatermarks
    with TableInfo<$EntityChangeWatermarksTable, EntityChangeWatermark> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $EntityChangeWatermarksTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _syncIdMeta = const VerificationMeta('syncId');
  @override
  late final GeneratedColumn<String> syncId = GeneratedColumn<String>(
      'sync_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _watermarkMeta =
      const VerificationMeta('watermark');
  @override
  late final GeneratedColumn<int> watermark = GeneratedColumn<int>(
      'watermark', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [syncId, watermark];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'entity_change_watermarks';
  @override
  VerificationContext validateIntegrity(
      Insertable<EntityChangeWatermark> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('sync_id')) {
      context.handle(_syncIdMeta,
          syncId.isAcceptableOrUnknown(data['sync_id']!, _syncIdMeta));
    } else if (isInserting) {
      context.missing(_syncIdMeta);
    }
    if (data.containsKey('watermark')) {
      context.handle(_watermarkMeta,
          watermark.isAcceptableOrUnknown(data['watermark']!, _watermarkMeta));
    } else if (isInserting) {
      context.missing(_watermarkMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {syncId};
  @override
  EntityChangeWatermark map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return EntityChangeWatermark(
      syncId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}sync_id'])!,
      watermark: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}watermark'])!,
    );
  }

  @override
  $EntityChangeWatermarksTable createAlias(String alias) {
    return $EntityChangeWatermarksTable(attachedDatabase, alias);
  }
}

class EntityChangeWatermark extends DataClass
    implements Insertable<EntityChangeWatermark> {
  final String syncId;
  final int watermark;
  const EntityChangeWatermark({required this.syncId, required this.watermark});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['sync_id'] = Variable<String>(syncId);
    map['watermark'] = Variable<int>(watermark);
    return map;
  }

  EntityChangeWatermarksCompanion toCompanion(bool nullToAbsent) {
    return EntityChangeWatermarksCompanion(
      syncId: Value(syncId),
      watermark: Value(watermark),
    );
  }

  factory EntityChangeWatermark.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return EntityChangeWatermark(
      syncId: serializer.fromJson<String>(json['syncId']),
      watermark: serializer.fromJson<int>(json['watermark']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'syncId': serializer.toJson<String>(syncId),
      'watermark': serializer.toJson<int>(watermark),
    };
  }

  EntityChangeWatermark copyWith({String? syncId, int? watermark}) =>
      EntityChangeWatermark(
        syncId: syncId ?? this.syncId,
        watermark: watermark ?? this.watermark,
      );
  EntityChangeWatermark copyWithCompanion(
      EntityChangeWatermarksCompanion data) {
    return EntityChangeWatermark(
      syncId: data.syncId.present ? data.syncId.value : this.syncId,
      watermark: data.watermark.present ? data.watermark.value : this.watermark,
    );
  }

  @override
  String toString() {
    return (StringBuffer('EntityChangeWatermark(')
          ..write('syncId: $syncId, ')
          ..write('watermark: $watermark')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(syncId, watermark);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is EntityChangeWatermark &&
          other.syncId == this.syncId &&
          other.watermark == this.watermark);
}

class EntityChangeWatermarksCompanion
    extends UpdateCompanion<EntityChangeWatermark> {
  final Value<String> syncId;
  final Value<int> watermark;
  final Value<int> rowid;
  const EntityChangeWatermarksCompanion({
    this.syncId = const Value.absent(),
    this.watermark = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  EntityChangeWatermarksCompanion.insert({
    required String syncId,
    required int watermark,
    this.rowid = const Value.absent(),
  })  : syncId = Value(syncId),
        watermark = Value(watermark);
  static Insertable<EntityChangeWatermark> custom({
    Expression<String>? syncId,
    Expression<int>? watermark,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (syncId != null) 'sync_id': syncId,
      if (watermark != null) 'watermark': watermark,
      if (rowid != null) 'rowid': rowid,
    });
  }

  EntityChangeWatermarksCompanion copyWith(
      {Value<String>? syncId, Value<int>? watermark, Value<int>? rowid}) {
    return EntityChangeWatermarksCompanion(
      syncId: syncId ?? this.syncId,
      watermark: watermark ?? this.watermark,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (syncId.present) {
      map['sync_id'] = Variable<String>(syncId.value);
    }
    if (watermark.present) {
      map['watermark'] = Variable<int>(watermark.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('EntityChangeWatermarksCompanion(')
          ..write('syncId: $syncId, ')
          ..write('watermark: $watermark, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SyncOpLogTable extends SyncOpLog
    with TableInfo<$SyncOpLogTable, SyncOpLogData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SyncOpLogTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _tsMeta = const VerificationMeta('ts');
  @override
  late final GeneratedColumn<DateTime> ts = GeneratedColumn<DateTime>(
      'ts', aliasedName, false,
      type: DriftSqlType.dateTime,
      requiredDuringInsert: false,
      defaultValue: currentDateAndTime);
  static const VerificationMeta _backendMeta =
      const VerificationMeta('backend');
  @override
  late final GeneratedColumn<String> backend = GeneratedColumn<String>(
      'backend', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _scenarioMeta =
      const VerificationMeta('scenario');
  @override
  late final GeneratedColumn<String> scenario = GeneratedColumn<String>(
      'scenario', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _outcomeMeta =
      const VerificationMeta('outcome');
  @override
  late final GeneratedColumn<String> outcome = GeneratedColumn<String>(
      'outcome', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _errorClassMeta =
      const VerificationMeta('errorClass');
  @override
  late final GeneratedColumn<String> errorClass = GeneratedColumn<String>(
      'error_class', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _ledgerIdMeta =
      const VerificationMeta('ledgerId');
  @override
  late final GeneratedColumn<int> ledgerId = GeneratedColumn<int>(
      'ledger_id', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _attemptsMeta =
      const VerificationMeta('attempts');
  @override
  late final GeneratedColumn<int> attempts = GeneratedColumn<int>(
      'attempts', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(1));
  static const VerificationMeta _durationMsMeta =
      const VerificationMeta('durationMs');
  @override
  late final GeneratedColumn<int> durationMs = GeneratedColumn<int>(
      'duration_ms', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  @override
  List<GeneratedColumn> get $columns => [
        id,
        ts,
        backend,
        scenario,
        outcome,
        errorClass,
        ledgerId,
        attempts,
        durationMs
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sync_op_log';
  @override
  VerificationContext validateIntegrity(Insertable<SyncOpLogData> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('ts')) {
      context.handle(_tsMeta, ts.isAcceptableOrUnknown(data['ts']!, _tsMeta));
    }
    if (data.containsKey('backend')) {
      context.handle(_backendMeta,
          backend.isAcceptableOrUnknown(data['backend']!, _backendMeta));
    } else if (isInserting) {
      context.missing(_backendMeta);
    }
    if (data.containsKey('scenario')) {
      context.handle(_scenarioMeta,
          scenario.isAcceptableOrUnknown(data['scenario']!, _scenarioMeta));
    } else if (isInserting) {
      context.missing(_scenarioMeta);
    }
    if (data.containsKey('outcome')) {
      context.handle(_outcomeMeta,
          outcome.isAcceptableOrUnknown(data['outcome']!, _outcomeMeta));
    } else if (isInserting) {
      context.missing(_outcomeMeta);
    }
    if (data.containsKey('error_class')) {
      context.handle(
          _errorClassMeta,
          errorClass.isAcceptableOrUnknown(
              data['error_class']!, _errorClassMeta));
    }
    if (data.containsKey('ledger_id')) {
      context.handle(_ledgerIdMeta,
          ledgerId.isAcceptableOrUnknown(data['ledger_id']!, _ledgerIdMeta));
    }
    if (data.containsKey('attempts')) {
      context.handle(_attemptsMeta,
          attempts.isAcceptableOrUnknown(data['attempts']!, _attemptsMeta));
    }
    if (data.containsKey('duration_ms')) {
      context.handle(
          _durationMsMeta,
          durationMs.isAcceptableOrUnknown(
              data['duration_ms']!, _durationMsMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  SyncOpLogData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SyncOpLogData(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      ts: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}ts'])!,
      backend: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}backend'])!,
      scenario: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}scenario'])!,
      outcome: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}outcome'])!,
      errorClass: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}error_class']),
      ledgerId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}ledger_id']),
      attempts: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}attempts'])!,
      durationMs: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}duration_ms']),
    );
  }

  @override
  $SyncOpLogTable createAlias(String alias) {
    return $SyncOpLogTable(attachedDatabase, alias);
  }
}

class SyncOpLogData extends DataClass implements Insertable<SyncOpLogData> {
  final int id;
  final DateTime ts;
  final String backend;
  final String scenario;
  final String outcome;
  final String? errorClass;
  final int? ledgerId;
  final int attempts;
  final int? durationMs;
  const SyncOpLogData(
      {required this.id,
      required this.ts,
      required this.backend,
      required this.scenario,
      required this.outcome,
      this.errorClass,
      this.ledgerId,
      required this.attempts,
      this.durationMs});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['ts'] = Variable<DateTime>(ts);
    map['backend'] = Variable<String>(backend);
    map['scenario'] = Variable<String>(scenario);
    map['outcome'] = Variable<String>(outcome);
    if (!nullToAbsent || errorClass != null) {
      map['error_class'] = Variable<String>(errorClass);
    }
    if (!nullToAbsent || ledgerId != null) {
      map['ledger_id'] = Variable<int>(ledgerId);
    }
    map['attempts'] = Variable<int>(attempts);
    if (!nullToAbsent || durationMs != null) {
      map['duration_ms'] = Variable<int>(durationMs);
    }
    return map;
  }

  SyncOpLogCompanion toCompanion(bool nullToAbsent) {
    return SyncOpLogCompanion(
      id: Value(id),
      ts: Value(ts),
      backend: Value(backend),
      scenario: Value(scenario),
      outcome: Value(outcome),
      errorClass: errorClass == null && nullToAbsent
          ? const Value.absent()
          : Value(errorClass),
      ledgerId: ledgerId == null && nullToAbsent
          ? const Value.absent()
          : Value(ledgerId),
      attempts: Value(attempts),
      durationMs: durationMs == null && nullToAbsent
          ? const Value.absent()
          : Value(durationMs),
    );
  }

  factory SyncOpLogData.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SyncOpLogData(
      id: serializer.fromJson<int>(json['id']),
      ts: serializer.fromJson<DateTime>(json['ts']),
      backend: serializer.fromJson<String>(json['backend']),
      scenario: serializer.fromJson<String>(json['scenario']),
      outcome: serializer.fromJson<String>(json['outcome']),
      errorClass: serializer.fromJson<String?>(json['errorClass']),
      ledgerId: serializer.fromJson<int?>(json['ledgerId']),
      attempts: serializer.fromJson<int>(json['attempts']),
      durationMs: serializer.fromJson<int?>(json['durationMs']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'ts': serializer.toJson<DateTime>(ts),
      'backend': serializer.toJson<String>(backend),
      'scenario': serializer.toJson<String>(scenario),
      'outcome': serializer.toJson<String>(outcome),
      'errorClass': serializer.toJson<String?>(errorClass),
      'ledgerId': serializer.toJson<int?>(ledgerId),
      'attempts': serializer.toJson<int>(attempts),
      'durationMs': serializer.toJson<int?>(durationMs),
    };
  }

  SyncOpLogData copyWith(
          {int? id,
          DateTime? ts,
          String? backend,
          String? scenario,
          String? outcome,
          Value<String?> errorClass = const Value.absent(),
          Value<int?> ledgerId = const Value.absent(),
          int? attempts,
          Value<int?> durationMs = const Value.absent()}) =>
      SyncOpLogData(
        id: id ?? this.id,
        ts: ts ?? this.ts,
        backend: backend ?? this.backend,
        scenario: scenario ?? this.scenario,
        outcome: outcome ?? this.outcome,
        errorClass: errorClass.present ? errorClass.value : this.errorClass,
        ledgerId: ledgerId.present ? ledgerId.value : this.ledgerId,
        attempts: attempts ?? this.attempts,
        durationMs: durationMs.present ? durationMs.value : this.durationMs,
      );
  SyncOpLogData copyWithCompanion(SyncOpLogCompanion data) {
    return SyncOpLogData(
      id: data.id.present ? data.id.value : this.id,
      ts: data.ts.present ? data.ts.value : this.ts,
      backend: data.backend.present ? data.backend.value : this.backend,
      scenario: data.scenario.present ? data.scenario.value : this.scenario,
      outcome: data.outcome.present ? data.outcome.value : this.outcome,
      errorClass:
          data.errorClass.present ? data.errorClass.value : this.errorClass,
      ledgerId: data.ledgerId.present ? data.ledgerId.value : this.ledgerId,
      attempts: data.attempts.present ? data.attempts.value : this.attempts,
      durationMs:
          data.durationMs.present ? data.durationMs.value : this.durationMs,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SyncOpLogData(')
          ..write('id: $id, ')
          ..write('ts: $ts, ')
          ..write('backend: $backend, ')
          ..write('scenario: $scenario, ')
          ..write('outcome: $outcome, ')
          ..write('errorClass: $errorClass, ')
          ..write('ledgerId: $ledgerId, ')
          ..write('attempts: $attempts, ')
          ..write('durationMs: $durationMs')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, ts, backend, scenario, outcome,
      errorClass, ledgerId, attempts, durationMs);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SyncOpLogData &&
          other.id == this.id &&
          other.ts == this.ts &&
          other.backend == this.backend &&
          other.scenario == this.scenario &&
          other.outcome == this.outcome &&
          other.errorClass == this.errorClass &&
          other.ledgerId == this.ledgerId &&
          other.attempts == this.attempts &&
          other.durationMs == this.durationMs);
}

class SyncOpLogCompanion extends UpdateCompanion<SyncOpLogData> {
  final Value<int> id;
  final Value<DateTime> ts;
  final Value<String> backend;
  final Value<String> scenario;
  final Value<String> outcome;
  final Value<String?> errorClass;
  final Value<int?> ledgerId;
  final Value<int> attempts;
  final Value<int?> durationMs;
  const SyncOpLogCompanion({
    this.id = const Value.absent(),
    this.ts = const Value.absent(),
    this.backend = const Value.absent(),
    this.scenario = const Value.absent(),
    this.outcome = const Value.absent(),
    this.errorClass = const Value.absent(),
    this.ledgerId = const Value.absent(),
    this.attempts = const Value.absent(),
    this.durationMs = const Value.absent(),
  });
  SyncOpLogCompanion.insert({
    this.id = const Value.absent(),
    this.ts = const Value.absent(),
    required String backend,
    required String scenario,
    required String outcome,
    this.errorClass = const Value.absent(),
    this.ledgerId = const Value.absent(),
    this.attempts = const Value.absent(),
    this.durationMs = const Value.absent(),
  })  : backend = Value(backend),
        scenario = Value(scenario),
        outcome = Value(outcome);
  static Insertable<SyncOpLogData> custom({
    Expression<int>? id,
    Expression<DateTime>? ts,
    Expression<String>? backend,
    Expression<String>? scenario,
    Expression<String>? outcome,
    Expression<String>? errorClass,
    Expression<int>? ledgerId,
    Expression<int>? attempts,
    Expression<int>? durationMs,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (ts != null) 'ts': ts,
      if (backend != null) 'backend': backend,
      if (scenario != null) 'scenario': scenario,
      if (outcome != null) 'outcome': outcome,
      if (errorClass != null) 'error_class': errorClass,
      if (ledgerId != null) 'ledger_id': ledgerId,
      if (attempts != null) 'attempts': attempts,
      if (durationMs != null) 'duration_ms': durationMs,
    });
  }

  SyncOpLogCompanion copyWith(
      {Value<int>? id,
      Value<DateTime>? ts,
      Value<String>? backend,
      Value<String>? scenario,
      Value<String>? outcome,
      Value<String?>? errorClass,
      Value<int?>? ledgerId,
      Value<int>? attempts,
      Value<int?>? durationMs}) {
    return SyncOpLogCompanion(
      id: id ?? this.id,
      ts: ts ?? this.ts,
      backend: backend ?? this.backend,
      scenario: scenario ?? this.scenario,
      outcome: outcome ?? this.outcome,
      errorClass: errorClass ?? this.errorClass,
      ledgerId: ledgerId ?? this.ledgerId,
      attempts: attempts ?? this.attempts,
      durationMs: durationMs ?? this.durationMs,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (ts.present) {
      map['ts'] = Variable<DateTime>(ts.value);
    }
    if (backend.present) {
      map['backend'] = Variable<String>(backend.value);
    }
    if (scenario.present) {
      map['scenario'] = Variable<String>(scenario.value);
    }
    if (outcome.present) {
      map['outcome'] = Variable<String>(outcome.value);
    }
    if (errorClass.present) {
      map['error_class'] = Variable<String>(errorClass.value);
    }
    if (ledgerId.present) {
      map['ledger_id'] = Variable<int>(ledgerId.value);
    }
    if (attempts.present) {
      map['attempts'] = Variable<int>(attempts.value);
    }
    if (durationMs.present) {
      map['duration_ms'] = Variable<int>(durationMs.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SyncOpLogCompanion(')
          ..write('id: $id, ')
          ..write('ts: $ts, ')
          ..write('backend: $backend, ')
          ..write('scenario: $scenario, ')
          ..write('outcome: $outcome, ')
          ..write('errorClass: $errorClass, ')
          ..write('ledgerId: $ledgerId, ')
          ..write('attempts: $attempts, ')
          ..write('durationMs: $durationMs')
          ..write(')'))
        .toString();
  }
}

class $StaleRemoteSlotsTable extends StaleRemoteSlots
    with TableInfo<$StaleRemoteSlotsTable, StaleRemoteSlot> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $StaleRemoteSlotsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _pathMeta = const VerificationMeta('path');
  @override
  late final GeneratedColumn<String> path = GeneratedColumn<String>(
      'path', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
      'created_at', aliasedName, false,
      type: DriftSqlType.dateTime,
      requiredDuringInsert: false,
      defaultValue: currentDateAndTime);
  @override
  List<GeneratedColumn> get $columns => [path, createdAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'stale_remote_slots';
  @override
  VerificationContext validateIntegrity(Insertable<StaleRemoteSlot> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('path')) {
      context.handle(
          _pathMeta, path.isAcceptableOrUnknown(data['path']!, _pathMeta));
    } else if (isInserting) {
      context.missing(_pathMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {path};
  @override
  StaleRemoteSlot map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return StaleRemoteSlot(
      path: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}path'])!,
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}created_at'])!,
    );
  }

  @override
  $StaleRemoteSlotsTable createAlias(String alias) {
    return $StaleRemoteSlotsTable(attachedDatabase, alias);
  }
}

class StaleRemoteSlot extends DataClass implements Insertable<StaleRemoteSlot> {
  final String path;
  final DateTime createdAt;
  const StaleRemoteSlot({required this.path, required this.createdAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['path'] = Variable<String>(path);
    map['created_at'] = Variable<DateTime>(createdAt);
    return map;
  }

  StaleRemoteSlotsCompanion toCompanion(bool nullToAbsent) {
    return StaleRemoteSlotsCompanion(
      path: Value(path),
      createdAt: Value(createdAt),
    );
  }

  factory StaleRemoteSlot.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return StaleRemoteSlot(
      path: serializer.fromJson<String>(json['path']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'path': serializer.toJson<String>(path),
      'createdAt': serializer.toJson<DateTime>(createdAt),
    };
  }

  StaleRemoteSlot copyWith({String? path, DateTime? createdAt}) =>
      StaleRemoteSlot(
        path: path ?? this.path,
        createdAt: createdAt ?? this.createdAt,
      );
  StaleRemoteSlot copyWithCompanion(StaleRemoteSlotsCompanion data) {
    return StaleRemoteSlot(
      path: data.path.present ? data.path.value : this.path,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('StaleRemoteSlot(')
          ..write('path: $path, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(path, createdAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is StaleRemoteSlot &&
          other.path == this.path &&
          other.createdAt == this.createdAt);
}

class StaleRemoteSlotsCompanion extends UpdateCompanion<StaleRemoteSlot> {
  final Value<String> path;
  final Value<DateTime> createdAt;
  final Value<int> rowid;
  const StaleRemoteSlotsCompanion({
    this.path = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  StaleRemoteSlotsCompanion.insert({
    required String path,
    this.createdAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : path = Value(path);
  static Insertable<StaleRemoteSlot> custom({
    Expression<String>? path,
    Expression<DateTime>? createdAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (path != null) 'path': path,
      if (createdAt != null) 'created_at': createdAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  StaleRemoteSlotsCompanion copyWith(
      {Value<String>? path, Value<DateTime>? createdAt, Value<int>? rowid}) {
    return StaleRemoteSlotsCompanion(
      path: path ?? this.path,
      createdAt: createdAt ?? this.createdAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (path.present) {
      map['path'] = Variable<String>(path.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('StaleRemoteSlotsCompanion(')
          ..write('path: $path, ')
          ..write('createdAt: $createdAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $DeletedTransactionsTable extends DeletedTransactions
    with TableInfo<$DeletedTransactionsTable, DeletedTransaction> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $DeletedTransactionsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _txIdMeta = const VerificationMeta('txId');
  @override
  late final GeneratedColumn<int> txId = GeneratedColumn<int>(
      'tx_id', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _ledgerIdMeta =
      const VerificationMeta('ledgerId');
  @override
  late final GeneratedColumn<int> ledgerId = GeneratedColumn<int>(
      'ledger_id', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _syncIdMeta = const VerificationMeta('syncId');
  @override
  late final GeneratedColumn<String> syncId = GeneratedColumn<String>(
      'sync_id', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _happenedAtMeta =
      const VerificationMeta('happenedAt');
  @override
  late final GeneratedColumn<DateTime> happenedAt = GeneratedColumn<DateTime>(
      'happened_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  static const VerificationMeta _deletedAtMeta =
      const VerificationMeta('deletedAt');
  @override
  late final GeneratedColumn<DateTime> deletedAt = GeneratedColumn<DateTime>(
      'deleted_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  static const VerificationMeta _payloadMeta =
      const VerificationMeta('payload');
  @override
  late final GeneratedColumn<String> payload = GeneratedColumn<String>(
      'payload', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns =>
      [txId, ledgerId, syncId, happenedAt, deletedAt, payload];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'deleted_transactions';
  @override
  VerificationContext validateIntegrity(Insertable<DeletedTransaction> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('tx_id')) {
      context.handle(
          _txIdMeta, txId.isAcceptableOrUnknown(data['tx_id']!, _txIdMeta));
    }
    if (data.containsKey('ledger_id')) {
      context.handle(_ledgerIdMeta,
          ledgerId.isAcceptableOrUnknown(data['ledger_id']!, _ledgerIdMeta));
    } else if (isInserting) {
      context.missing(_ledgerIdMeta);
    }
    if (data.containsKey('sync_id')) {
      context.handle(_syncIdMeta,
          syncId.isAcceptableOrUnknown(data['sync_id']!, _syncIdMeta));
    }
    if (data.containsKey('happened_at')) {
      context.handle(
          _happenedAtMeta,
          happenedAt.isAcceptableOrUnknown(
              data['happened_at']!, _happenedAtMeta));
    } else if (isInserting) {
      context.missing(_happenedAtMeta);
    }
    if (data.containsKey('deleted_at')) {
      context.handle(_deletedAtMeta,
          deletedAt.isAcceptableOrUnknown(data['deleted_at']!, _deletedAtMeta));
    } else if (isInserting) {
      context.missing(_deletedAtMeta);
    }
    if (data.containsKey('payload')) {
      context.handle(_payloadMeta,
          payload.isAcceptableOrUnknown(data['payload']!, _payloadMeta));
    } else if (isInserting) {
      context.missing(_payloadMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {txId};
  @override
  DeletedTransaction map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DeletedTransaction(
      txId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}tx_id'])!,
      ledgerId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}ledger_id'])!,
      syncId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}sync_id']),
      happenedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}happened_at'])!,
      deletedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}deleted_at'])!,
      payload: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}payload'])!,
    );
  }

  @override
  $DeletedTransactionsTable createAlias(String alias) {
    return $DeletedTransactionsTable(attachedDatabase, alias);
  }
}

class DeletedTransaction extends DataClass
    implements Insertable<DeletedTransaction> {
  /// 原 transactions.id，同时作主键：一笔交易最多进一次回收站。
  final int txId;
  final int ledgerId;
  final String? syncId;

  /// 业务时间冗余列：回收站列表排序/展示用，不必解析 payload。
  final DateTime happenedAt;
  final DateTime deletedAt;
  final String payload;
  const DeletedTransaction(
      {required this.txId,
      required this.ledgerId,
      this.syncId,
      required this.happenedAt,
      required this.deletedAt,
      required this.payload});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['tx_id'] = Variable<int>(txId);
    map['ledger_id'] = Variable<int>(ledgerId);
    if (!nullToAbsent || syncId != null) {
      map['sync_id'] = Variable<String>(syncId);
    }
    map['happened_at'] = Variable<DateTime>(happenedAt);
    map['deleted_at'] = Variable<DateTime>(deletedAt);
    map['payload'] = Variable<String>(payload);
    return map;
  }

  DeletedTransactionsCompanion toCompanion(bool nullToAbsent) {
    return DeletedTransactionsCompanion(
      txId: Value(txId),
      ledgerId: Value(ledgerId),
      syncId:
          syncId == null && nullToAbsent ? const Value.absent() : Value(syncId),
      happenedAt: Value(happenedAt),
      deletedAt: Value(deletedAt),
      payload: Value(payload),
    );
  }

  factory DeletedTransaction.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DeletedTransaction(
      txId: serializer.fromJson<int>(json['txId']),
      ledgerId: serializer.fromJson<int>(json['ledgerId']),
      syncId: serializer.fromJson<String?>(json['syncId']),
      happenedAt: serializer.fromJson<DateTime>(json['happenedAt']),
      deletedAt: serializer.fromJson<DateTime>(json['deletedAt']),
      payload: serializer.fromJson<String>(json['payload']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'txId': serializer.toJson<int>(txId),
      'ledgerId': serializer.toJson<int>(ledgerId),
      'syncId': serializer.toJson<String?>(syncId),
      'happenedAt': serializer.toJson<DateTime>(happenedAt),
      'deletedAt': serializer.toJson<DateTime>(deletedAt),
      'payload': serializer.toJson<String>(payload),
    };
  }

  DeletedTransaction copyWith(
          {int? txId,
          int? ledgerId,
          Value<String?> syncId = const Value.absent(),
          DateTime? happenedAt,
          DateTime? deletedAt,
          String? payload}) =>
      DeletedTransaction(
        txId: txId ?? this.txId,
        ledgerId: ledgerId ?? this.ledgerId,
        syncId: syncId.present ? syncId.value : this.syncId,
        happenedAt: happenedAt ?? this.happenedAt,
        deletedAt: deletedAt ?? this.deletedAt,
        payload: payload ?? this.payload,
      );
  DeletedTransaction copyWithCompanion(DeletedTransactionsCompanion data) {
    return DeletedTransaction(
      txId: data.txId.present ? data.txId.value : this.txId,
      ledgerId: data.ledgerId.present ? data.ledgerId.value : this.ledgerId,
      syncId: data.syncId.present ? data.syncId.value : this.syncId,
      happenedAt:
          data.happenedAt.present ? data.happenedAt.value : this.happenedAt,
      deletedAt: data.deletedAt.present ? data.deletedAt.value : this.deletedAt,
      payload: data.payload.present ? data.payload.value : this.payload,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DeletedTransaction(')
          ..write('txId: $txId, ')
          ..write('ledgerId: $ledgerId, ')
          ..write('syncId: $syncId, ')
          ..write('happenedAt: $happenedAt, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('payload: $payload')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(txId, ledgerId, syncId, happenedAt, deletedAt, payload);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DeletedTransaction &&
          other.txId == this.txId &&
          other.ledgerId == this.ledgerId &&
          other.syncId == this.syncId &&
          other.happenedAt == this.happenedAt &&
          other.deletedAt == this.deletedAt &&
          other.payload == this.payload);
}

class DeletedTransactionsCompanion extends UpdateCompanion<DeletedTransaction> {
  final Value<int> txId;
  final Value<int> ledgerId;
  final Value<String?> syncId;
  final Value<DateTime> happenedAt;
  final Value<DateTime> deletedAt;
  final Value<String> payload;
  const DeletedTransactionsCompanion({
    this.txId = const Value.absent(),
    this.ledgerId = const Value.absent(),
    this.syncId = const Value.absent(),
    this.happenedAt = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.payload = const Value.absent(),
  });
  DeletedTransactionsCompanion.insert({
    this.txId = const Value.absent(),
    required int ledgerId,
    this.syncId = const Value.absent(),
    required DateTime happenedAt,
    required DateTime deletedAt,
    required String payload,
  })  : ledgerId = Value(ledgerId),
        happenedAt = Value(happenedAt),
        deletedAt = Value(deletedAt),
        payload = Value(payload);
  static Insertable<DeletedTransaction> custom({
    Expression<int>? txId,
    Expression<int>? ledgerId,
    Expression<String>? syncId,
    Expression<DateTime>? happenedAt,
    Expression<DateTime>? deletedAt,
    Expression<String>? payload,
  }) {
    return RawValuesInsertable({
      if (txId != null) 'tx_id': txId,
      if (ledgerId != null) 'ledger_id': ledgerId,
      if (syncId != null) 'sync_id': syncId,
      if (happenedAt != null) 'happened_at': happenedAt,
      if (deletedAt != null) 'deleted_at': deletedAt,
      if (payload != null) 'payload': payload,
    });
  }

  DeletedTransactionsCompanion copyWith(
      {Value<int>? txId,
      Value<int>? ledgerId,
      Value<String?>? syncId,
      Value<DateTime>? happenedAt,
      Value<DateTime>? deletedAt,
      Value<String>? payload}) {
    return DeletedTransactionsCompanion(
      txId: txId ?? this.txId,
      ledgerId: ledgerId ?? this.ledgerId,
      syncId: syncId ?? this.syncId,
      happenedAt: happenedAt ?? this.happenedAt,
      deletedAt: deletedAt ?? this.deletedAt,
      payload: payload ?? this.payload,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (txId.present) {
      map['tx_id'] = Variable<int>(txId.value);
    }
    if (ledgerId.present) {
      map['ledger_id'] = Variable<int>(ledgerId.value);
    }
    if (syncId.present) {
      map['sync_id'] = Variable<String>(syncId.value);
    }
    if (happenedAt.present) {
      map['happened_at'] = Variable<DateTime>(happenedAt.value);
    }
    if (deletedAt.present) {
      map['deleted_at'] = Variable<DateTime>(deletedAt.value);
    }
    if (payload.present) {
      map['payload'] = Variable<String>(payload.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('DeletedTransactionsCompanion(')
          ..write('txId: $txId, ')
          ..write('ledgerId: $ledgerId, ')
          ..write('syncId: $syncId, ')
          ..write('happenedAt: $happenedAt, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('payload: $payload')
          ..write(')'))
        .toString();
  }
}

class $HolidayEntriesTable extends HolidayEntries
    with TableInfo<$HolidayEntriesTable, HolidayEntry> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $HolidayEntriesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _dateMeta = const VerificationMeta('date');
  @override
  late final GeneratedColumn<String> date = GeneratedColumn<String>(
      'date', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _yearMeta = const VerificationMeta('year');
  @override
  late final GeneratedColumn<int> year = GeneratedColumn<int>(
      'year', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _isHolidayMeta =
      const VerificationMeta('isHoliday');
  @override
  late final GeneratedColumn<bool> isHoliday = GeneratedColumn<bool>(
      'is_holiday', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: true,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("is_holiday" IN (0, 1))'));
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
      'name', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _fetchedAtMeta =
      const VerificationMeta('fetchedAt');
  @override
  late final GeneratedColumn<DateTime> fetchedAt = GeneratedColumn<DateTime>(
      'fetched_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns =>
      [date, year, isHoliday, name, fetchedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'holiday_entries';
  @override
  VerificationContext validateIntegrity(Insertable<HolidayEntry> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('date')) {
      context.handle(
          _dateMeta, date.isAcceptableOrUnknown(data['date']!, _dateMeta));
    } else if (isInserting) {
      context.missing(_dateMeta);
    }
    if (data.containsKey('year')) {
      context.handle(
          _yearMeta, year.isAcceptableOrUnknown(data['year']!, _yearMeta));
    } else if (isInserting) {
      context.missing(_yearMeta);
    }
    if (data.containsKey('is_holiday')) {
      context.handle(_isHolidayMeta,
          isHoliday.isAcceptableOrUnknown(data['is_holiday']!, _isHolidayMeta));
    } else if (isInserting) {
      context.missing(_isHolidayMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
          _nameMeta, name.isAcceptableOrUnknown(data['name']!, _nameMeta));
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('fetched_at')) {
      context.handle(_fetchedAtMeta,
          fetchedAt.isAcceptableOrUnknown(data['fetched_at']!, _fetchedAtMeta));
    } else if (isInserting) {
      context.missing(_fetchedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {date};
  @override
  HolidayEntry map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return HolidayEntry(
      date: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}date'])!,
      year: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}year'])!,
      isHoliday: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}is_holiday'])!,
      name: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}name'])!,
      fetchedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}fetched_at'])!,
    );
  }

  @override
  $HolidayEntriesTable createAlias(String alias) {
    return $HolidayEntriesTable(attachedDatabase, alias);
  }
}

class HolidayEntry extends DataClass implements Insertable<HolidayEntry> {
  /// 'YYYY-MM-DD'
  final String date;

  /// 公历年（整年替换 / 设置页按年分组都靠它）
  final int year;

  /// true = 放假日；false = 调休补班日（要上班的周末）
  final bool isHoliday;

  /// 节假日名称（如「春节」「春节后补班」）
  final String name;
  final DateTime fetchedAt;
  const HolidayEntry(
      {required this.date,
      required this.year,
      required this.isHoliday,
      required this.name,
      required this.fetchedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['date'] = Variable<String>(date);
    map['year'] = Variable<int>(year);
    map['is_holiday'] = Variable<bool>(isHoliday);
    map['name'] = Variable<String>(name);
    map['fetched_at'] = Variable<DateTime>(fetchedAt);
    return map;
  }

  HolidayEntriesCompanion toCompanion(bool nullToAbsent) {
    return HolidayEntriesCompanion(
      date: Value(date),
      year: Value(year),
      isHoliday: Value(isHoliday),
      name: Value(name),
      fetchedAt: Value(fetchedAt),
    );
  }

  factory HolidayEntry.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return HolidayEntry(
      date: serializer.fromJson<String>(json['date']),
      year: serializer.fromJson<int>(json['year']),
      isHoliday: serializer.fromJson<bool>(json['isHoliday']),
      name: serializer.fromJson<String>(json['name']),
      fetchedAt: serializer.fromJson<DateTime>(json['fetchedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'date': serializer.toJson<String>(date),
      'year': serializer.toJson<int>(year),
      'isHoliday': serializer.toJson<bool>(isHoliday),
      'name': serializer.toJson<String>(name),
      'fetchedAt': serializer.toJson<DateTime>(fetchedAt),
    };
  }

  HolidayEntry copyWith(
          {String? date,
          int? year,
          bool? isHoliday,
          String? name,
          DateTime? fetchedAt}) =>
      HolidayEntry(
        date: date ?? this.date,
        year: year ?? this.year,
        isHoliday: isHoliday ?? this.isHoliday,
        name: name ?? this.name,
        fetchedAt: fetchedAt ?? this.fetchedAt,
      );
  HolidayEntry copyWithCompanion(HolidayEntriesCompanion data) {
    return HolidayEntry(
      date: data.date.present ? data.date.value : this.date,
      year: data.year.present ? data.year.value : this.year,
      isHoliday: data.isHoliday.present ? data.isHoliday.value : this.isHoliday,
      name: data.name.present ? data.name.value : this.name,
      fetchedAt: data.fetchedAt.present ? data.fetchedAt.value : this.fetchedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('HolidayEntry(')
          ..write('date: $date, ')
          ..write('year: $year, ')
          ..write('isHoliday: $isHoliday, ')
          ..write('name: $name, ')
          ..write('fetchedAt: $fetchedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(date, year, isHoliday, name, fetchedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is HolidayEntry &&
          other.date == this.date &&
          other.year == this.year &&
          other.isHoliday == this.isHoliday &&
          other.name == this.name &&
          other.fetchedAt == this.fetchedAt);
}

class HolidayEntriesCompanion extends UpdateCompanion<HolidayEntry> {
  final Value<String> date;
  final Value<int> year;
  final Value<bool> isHoliday;
  final Value<String> name;
  final Value<DateTime> fetchedAt;
  final Value<int> rowid;
  const HolidayEntriesCompanion({
    this.date = const Value.absent(),
    this.year = const Value.absent(),
    this.isHoliday = const Value.absent(),
    this.name = const Value.absent(),
    this.fetchedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  HolidayEntriesCompanion.insert({
    required String date,
    required int year,
    required bool isHoliday,
    required String name,
    required DateTime fetchedAt,
    this.rowid = const Value.absent(),
  })  : date = Value(date),
        year = Value(year),
        isHoliday = Value(isHoliday),
        name = Value(name),
        fetchedAt = Value(fetchedAt);
  static Insertable<HolidayEntry> custom({
    Expression<String>? date,
    Expression<int>? year,
    Expression<bool>? isHoliday,
    Expression<String>? name,
    Expression<DateTime>? fetchedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (date != null) 'date': date,
      if (year != null) 'year': year,
      if (isHoliday != null) 'is_holiday': isHoliday,
      if (name != null) 'name': name,
      if (fetchedAt != null) 'fetched_at': fetchedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  HolidayEntriesCompanion copyWith(
      {Value<String>? date,
      Value<int>? year,
      Value<bool>? isHoliday,
      Value<String>? name,
      Value<DateTime>? fetchedAt,
      Value<int>? rowid}) {
    return HolidayEntriesCompanion(
      date: date ?? this.date,
      year: year ?? this.year,
      isHoliday: isHoliday ?? this.isHoliday,
      name: name ?? this.name,
      fetchedAt: fetchedAt ?? this.fetchedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (date.present) {
      map['date'] = Variable<String>(date.value);
    }
    if (year.present) {
      map['year'] = Variable<int>(year.value);
    }
    if (isHoliday.present) {
      map['is_holiday'] = Variable<bool>(isHoliday.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (fetchedAt.present) {
      map['fetched_at'] = Variable<DateTime>(fetchedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('HolidayEntriesCompanion(')
          ..write('date: $date, ')
          ..write('year: $year, ')
          ..write('isHoliday: $isHoliday, ')
          ..write('name: $name, ')
          ..write('fetchedAt: $fetchedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $HolidayUpdateMetaTable extends HolidayUpdateMeta
    with TableInfo<$HolidayUpdateMetaTable, HolidayUpdateMetaData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $HolidayUpdateMetaTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _lastUpdateMsMeta =
      const VerificationMeta('lastUpdateMs');
  @override
  late final GeneratedColumn<int> lastUpdateMs = GeneratedColumn<int>(
      'last_update_ms', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _lastAttemptMsMeta =
      const VerificationMeta('lastAttemptMs');
  @override
  late final GeneratedColumn<int> lastAttemptMs = GeneratedColumn<int>(
      'last_attempt_ms', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _failureCountMeta =
      const VerificationMeta('failureCount');
  @override
  late final GeneratedColumn<int> failureCount = GeneratedColumn<int>(
      'failure_count', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _autoEnabledMeta =
      const VerificationMeta('autoEnabled');
  @override
  late final GeneratedColumn<bool> autoEnabled = GeneratedColumn<bool>(
      'auto_enabled', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints: GeneratedColumn.constraintIsAlways(
          'CHECK ("auto_enabled" IN (0, 1))'),
      defaultValue: const Constant(true));
  static const VerificationMeta _updatedAtMeta =
      const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
      'updated_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns =>
      [id, lastUpdateMs, lastAttemptMs, failureCount, autoEnabled, updatedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'holiday_update_meta';
  @override
  VerificationContext validateIntegrity(
      Insertable<HolidayUpdateMetaData> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('last_update_ms')) {
      context.handle(
          _lastUpdateMsMeta,
          lastUpdateMs.isAcceptableOrUnknown(
              data['last_update_ms']!, _lastUpdateMsMeta));
    }
    if (data.containsKey('last_attempt_ms')) {
      context.handle(
          _lastAttemptMsMeta,
          lastAttemptMs.isAcceptableOrUnknown(
              data['last_attempt_ms']!, _lastAttemptMsMeta));
    }
    if (data.containsKey('failure_count')) {
      context.handle(
          _failureCountMeta,
          failureCount.isAcceptableOrUnknown(
              data['failure_count']!, _failureCountMeta));
    }
    if (data.containsKey('auto_enabled')) {
      context.handle(
          _autoEnabledMeta,
          autoEnabled.isAcceptableOrUnknown(
              data['auto_enabled']!, _autoEnabledMeta));
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta,
          updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  HolidayUpdateMetaData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return HolidayUpdateMetaData(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      lastUpdateMs: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}last_update_ms'])!,
      lastAttemptMs: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}last_attempt_ms'])!,
      failureCount: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}failure_count'])!,
      autoEnabled: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}auto_enabled'])!,
      updatedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}updated_at'])!,
    );
  }

  @override
  $HolidayUpdateMetaTable createAlias(String alias) {
    return $HolidayUpdateMetaTable(attachedDatabase, alias);
  }
}

class HolidayUpdateMetaData extends DataClass
    implements Insertable<HolidayUpdateMetaData> {
  /// 恒 1
  final int id;

  /// 上次**成功**更新时间（epoch ms；0 = 从未成功）
  final int lastUpdateMs;

  /// 上次尝试时间（epoch ms；成功 / 失败都写）
  final int lastAttemptMs;

  /// 连续失败次数（成功后清零）
  final int failureCount;

  /// 「每月自动更新」开关
  final bool autoEnabled;
  final DateTime updatedAt;
  const HolidayUpdateMetaData(
      {required this.id,
      required this.lastUpdateMs,
      required this.lastAttemptMs,
      required this.failureCount,
      required this.autoEnabled,
      required this.updatedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['last_update_ms'] = Variable<int>(lastUpdateMs);
    map['last_attempt_ms'] = Variable<int>(lastAttemptMs);
    map['failure_count'] = Variable<int>(failureCount);
    map['auto_enabled'] = Variable<bool>(autoEnabled);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    return map;
  }

  HolidayUpdateMetaCompanion toCompanion(bool nullToAbsent) {
    return HolidayUpdateMetaCompanion(
      id: Value(id),
      lastUpdateMs: Value(lastUpdateMs),
      lastAttemptMs: Value(lastAttemptMs),
      failureCount: Value(failureCount),
      autoEnabled: Value(autoEnabled),
      updatedAt: Value(updatedAt),
    );
  }

  factory HolidayUpdateMetaData.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return HolidayUpdateMetaData(
      id: serializer.fromJson<int>(json['id']),
      lastUpdateMs: serializer.fromJson<int>(json['lastUpdateMs']),
      lastAttemptMs: serializer.fromJson<int>(json['lastAttemptMs']),
      failureCount: serializer.fromJson<int>(json['failureCount']),
      autoEnabled: serializer.fromJson<bool>(json['autoEnabled']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'lastUpdateMs': serializer.toJson<int>(lastUpdateMs),
      'lastAttemptMs': serializer.toJson<int>(lastAttemptMs),
      'failureCount': serializer.toJson<int>(failureCount),
      'autoEnabled': serializer.toJson<bool>(autoEnabled),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
    };
  }

  HolidayUpdateMetaData copyWith(
          {int? id,
          int? lastUpdateMs,
          int? lastAttemptMs,
          int? failureCount,
          bool? autoEnabled,
          DateTime? updatedAt}) =>
      HolidayUpdateMetaData(
        id: id ?? this.id,
        lastUpdateMs: lastUpdateMs ?? this.lastUpdateMs,
        lastAttemptMs: lastAttemptMs ?? this.lastAttemptMs,
        failureCount: failureCount ?? this.failureCount,
        autoEnabled: autoEnabled ?? this.autoEnabled,
        updatedAt: updatedAt ?? this.updatedAt,
      );
  HolidayUpdateMetaData copyWithCompanion(HolidayUpdateMetaCompanion data) {
    return HolidayUpdateMetaData(
      id: data.id.present ? data.id.value : this.id,
      lastUpdateMs: data.lastUpdateMs.present
          ? data.lastUpdateMs.value
          : this.lastUpdateMs,
      lastAttemptMs: data.lastAttemptMs.present
          ? data.lastAttemptMs.value
          : this.lastAttemptMs,
      failureCount: data.failureCount.present
          ? data.failureCount.value
          : this.failureCount,
      autoEnabled:
          data.autoEnabled.present ? data.autoEnabled.value : this.autoEnabled,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('HolidayUpdateMetaData(')
          ..write('id: $id, ')
          ..write('lastUpdateMs: $lastUpdateMs, ')
          ..write('lastAttemptMs: $lastAttemptMs, ')
          ..write('failureCount: $failureCount, ')
          ..write('autoEnabled: $autoEnabled, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      id, lastUpdateMs, lastAttemptMs, failureCount, autoEnabled, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is HolidayUpdateMetaData &&
          other.id == this.id &&
          other.lastUpdateMs == this.lastUpdateMs &&
          other.lastAttemptMs == this.lastAttemptMs &&
          other.failureCount == this.failureCount &&
          other.autoEnabled == this.autoEnabled &&
          other.updatedAt == this.updatedAt);
}

class HolidayUpdateMetaCompanion
    extends UpdateCompanion<HolidayUpdateMetaData> {
  final Value<int> id;
  final Value<int> lastUpdateMs;
  final Value<int> lastAttemptMs;
  final Value<int> failureCount;
  final Value<bool> autoEnabled;
  final Value<DateTime> updatedAt;
  const HolidayUpdateMetaCompanion({
    this.id = const Value.absent(),
    this.lastUpdateMs = const Value.absent(),
    this.lastAttemptMs = const Value.absent(),
    this.failureCount = const Value.absent(),
    this.autoEnabled = const Value.absent(),
    this.updatedAt = const Value.absent(),
  });
  HolidayUpdateMetaCompanion.insert({
    this.id = const Value.absent(),
    this.lastUpdateMs = const Value.absent(),
    this.lastAttemptMs = const Value.absent(),
    this.failureCount = const Value.absent(),
    this.autoEnabled = const Value.absent(),
    required DateTime updatedAt,
  }) : updatedAt = Value(updatedAt);
  static Insertable<HolidayUpdateMetaData> custom({
    Expression<int>? id,
    Expression<int>? lastUpdateMs,
    Expression<int>? lastAttemptMs,
    Expression<int>? failureCount,
    Expression<bool>? autoEnabled,
    Expression<DateTime>? updatedAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (lastUpdateMs != null) 'last_update_ms': lastUpdateMs,
      if (lastAttemptMs != null) 'last_attempt_ms': lastAttemptMs,
      if (failureCount != null) 'failure_count': failureCount,
      if (autoEnabled != null) 'auto_enabled': autoEnabled,
      if (updatedAt != null) 'updated_at': updatedAt,
    });
  }

  HolidayUpdateMetaCompanion copyWith(
      {Value<int>? id,
      Value<int>? lastUpdateMs,
      Value<int>? lastAttemptMs,
      Value<int>? failureCount,
      Value<bool>? autoEnabled,
      Value<DateTime>? updatedAt}) {
    return HolidayUpdateMetaCompanion(
      id: id ?? this.id,
      lastUpdateMs: lastUpdateMs ?? this.lastUpdateMs,
      lastAttemptMs: lastAttemptMs ?? this.lastAttemptMs,
      failureCount: failureCount ?? this.failureCount,
      autoEnabled: autoEnabled ?? this.autoEnabled,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (lastUpdateMs.present) {
      map['last_update_ms'] = Variable<int>(lastUpdateMs.value);
    }
    if (lastAttemptMs.present) {
      map['last_attempt_ms'] = Variable<int>(lastAttemptMs.value);
    }
    if (failureCount.present) {
      map['failure_count'] = Variable<int>(failureCount.value);
    }
    if (autoEnabled.present) {
      map['auto_enabled'] = Variable<bool>(autoEnabled.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('HolidayUpdateMetaCompanion(')
          ..write('id: $id, ')
          ..write('lastUpdateMs: $lastUpdateMs, ')
          ..write('lastAttemptMs: $lastAttemptMs, ')
          ..write('failureCount: $failureCount, ')
          ..write('autoEnabled: $autoEnabled, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }
}

abstract class _$PiggyDatabase extends GeneratedDatabase {
  _$PiggyDatabase(QueryExecutor e) : super(e);
  $PiggyDatabaseManager get managers => $PiggyDatabaseManager(this);
  late final $LedgersTable ledgers = $LedgersTable(this);
  late final $AccountsTable accounts = $AccountsTable(this);
  late final $HoldingsTable holdings = $HoldingsTable(this);
  late final $CategoriesTable categories = $CategoriesTable(this);
  late final $TransactionsTable transactions = $TransactionsTable(this);
  late final $RecurringTransactionsTable recurringTransactions =
      $RecurringTransactionsTable(this);
  late final $ConversationsTable conversations = $ConversationsTable(this);
  late final $MessagesTable messages = $MessagesTable(this);
  late final $TagsTable tags = $TagsTable(this);
  late final $CustomFieldDefinitionsTable customFieldDefinitions =
      $CustomFieldDefinitionsTable(this);
  late final $TransactionTagsTable transactionTags =
      $TransactionTagsTable(this);
  late final $BudgetsTable budgets = $BudgetsTable(this);
  late final $SavingsGoalsTable savingsGoals = $SavingsGoalsTable(this);
  late final $TransactionAttachmentsTable transactionAttachments =
      $TransactionAttachmentsTable(this);
  late final $LocalChangesTable localChanges = $LocalChangesTable(this);
  late final $SyncPullErrorsTable syncPullErrors = $SyncPullErrorsTable(this);
  late final $ExchangeRatesTable exchangeRates = $ExchangeRatesTable(this);
  late final $ExchangeRateOverridesTable exchangeRateOverrides =
      $ExchangeRateOverridesTable(this);
  late final $EntityChangeWatermarksTable entityChangeWatermarks =
      $EntityChangeWatermarksTable(this);
  late final $SyncOpLogTable syncOpLog = $SyncOpLogTable(this);
  late final $StaleRemoteSlotsTable staleRemoteSlots =
      $StaleRemoteSlotsTable(this);
  late final $DeletedTransactionsTable deletedTransactions =
      $DeletedTransactionsTable(this);
  late final $HolidayEntriesTable holidayEntries = $HolidayEntriesTable(this);
  late final $HolidayUpdateMetaTable holidayUpdateMeta =
      $HolidayUpdateMetaTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
        ledgers,
        accounts,
        holdings,
        categories,
        transactions,
        recurringTransactions,
        conversations,
        messages,
        tags,
        customFieldDefinitions,
        transactionTags,
        budgets,
        savingsGoals,
        transactionAttachments,
        localChanges,
        syncPullErrors,
        exchangeRates,
        exchangeRateOverrides,
        entityChangeWatermarks,
        syncOpLog,
        staleRemoteSlots,
        deletedTransactions,
        holidayEntries,
        holidayUpdateMeta
      ];
}

typedef $$LedgersTableCreateCompanionBuilder = LedgersCompanion Function({
  Value<int> id,
  required String name,
  Value<String> currency,
  Value<String> type,
  Value<DateTime> createdAt,
  Value<String?> syncId,
  Value<int> monthStartDay,
  Value<DateTime?> updatedAt,
});
typedef $$LedgersTableUpdateCompanionBuilder = LedgersCompanion Function({
  Value<int> id,
  Value<String> name,
  Value<String> currency,
  Value<String> type,
  Value<DateTime> createdAt,
  Value<String?> syncId,
  Value<int> monthStartDay,
  Value<DateTime?> updatedAt,
});

class $$LedgersTableFilterComposer
    extends Composer<_$PiggyDatabase, $LedgersTable> {
  $$LedgersTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get currency => $composableBuilder(
      column: $table.currency, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get type => $composableBuilder(
      column: $table.type, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get syncId => $composableBuilder(
      column: $table.syncId, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get monthStartDay => $composableBuilder(
      column: $table.monthStartDay, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnFilters(column));
}

class $$LedgersTableOrderingComposer
    extends Composer<_$PiggyDatabase, $LedgersTable> {
  $$LedgersTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get currency => $composableBuilder(
      column: $table.currency, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get type => $composableBuilder(
      column: $table.type, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get syncId => $composableBuilder(
      column: $table.syncId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get monthStartDay => $composableBuilder(
      column: $table.monthStartDay,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnOrderings(column));
}

class $$LedgersTableAnnotationComposer
    extends Composer<_$PiggyDatabase, $LedgersTable> {
  $$LedgersTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get currency =>
      $composableBuilder(column: $table.currency, builder: (column) => column);

  GeneratedColumn<String> get type =>
      $composableBuilder(column: $table.type, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<String> get syncId =>
      $composableBuilder(column: $table.syncId, builder: (column) => column);

  GeneratedColumn<int> get monthStartDay => $composableBuilder(
      column: $table.monthStartDay, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$LedgersTableTableManager extends RootTableManager<
    _$PiggyDatabase,
    $LedgersTable,
    Ledger,
    $$LedgersTableFilterComposer,
    $$LedgersTableOrderingComposer,
    $$LedgersTableAnnotationComposer,
    $$LedgersTableCreateCompanionBuilder,
    $$LedgersTableUpdateCompanionBuilder,
    (Ledger, BaseReferences<_$PiggyDatabase, $LedgersTable, Ledger>),
    Ledger,
    PrefetchHooks Function()> {
  $$LedgersTableTableManager(_$PiggyDatabase db, $LedgersTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LedgersTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LedgersTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LedgersTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> name = const Value.absent(),
            Value<String> currency = const Value.absent(),
            Value<String> type = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
            Value<String?> syncId = const Value.absent(),
            Value<int> monthStartDay = const Value.absent(),
            Value<DateTime?> updatedAt = const Value.absent(),
          }) =>
              LedgersCompanion(
            id: id,
            name: name,
            currency: currency,
            type: type,
            createdAt: createdAt,
            syncId: syncId,
            monthStartDay: monthStartDay,
            updatedAt: updatedAt,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required String name,
            Value<String> currency = const Value.absent(),
            Value<String> type = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
            Value<String?> syncId = const Value.absent(),
            Value<int> monthStartDay = const Value.absent(),
            Value<DateTime?> updatedAt = const Value.absent(),
          }) =>
              LedgersCompanion.insert(
            id: id,
            name: name,
            currency: currency,
            type: type,
            createdAt: createdAt,
            syncId: syncId,
            monthStartDay: monthStartDay,
            updatedAt: updatedAt,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable<$LedgersTable, Ledger>(table),
                    BaseReferences<_$PiggyDatabase, $LedgersTable, Ledger>(
                        db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$LedgersTableProcessedTableManager = ProcessedTableManager<
    _$PiggyDatabase,
    $LedgersTable,
    Ledger,
    $$LedgersTableFilterComposer,
    $$LedgersTableOrderingComposer,
    $$LedgersTableAnnotationComposer,
    $$LedgersTableCreateCompanionBuilder,
    $$LedgersTableUpdateCompanionBuilder,
    (Ledger, BaseReferences<_$PiggyDatabase, $LedgersTable, Ledger>),
    Ledger,
    PrefetchHooks Function()>;
typedef $$AccountsTableCreateCompanionBuilder = AccountsCompanion Function({
  Value<int> id,
  required int ledgerId,
  required String name,
  Value<String> type,
  Value<String> currency,
  Value<double> initialBalance,
  Value<DateTime?> createdAt,
  Value<DateTime?> updatedAt,
  Value<int> sortOrder,
  Value<double?> creditLimit,
  Value<int?> billingDay,
  Value<int?> paymentDueDay,
  Value<String?> bankName,
  Value<String?> cardLastFour,
  Value<String?> note,
  Value<String?> syncId,
  Value<bool> hidden,
});
typedef $$AccountsTableUpdateCompanionBuilder = AccountsCompanion Function({
  Value<int> id,
  Value<int> ledgerId,
  Value<String> name,
  Value<String> type,
  Value<String> currency,
  Value<double> initialBalance,
  Value<DateTime?> createdAt,
  Value<DateTime?> updatedAt,
  Value<int> sortOrder,
  Value<double?> creditLimit,
  Value<int?> billingDay,
  Value<int?> paymentDueDay,
  Value<String?> bankName,
  Value<String?> cardLastFour,
  Value<String?> note,
  Value<String?> syncId,
  Value<bool> hidden,
});

class $$AccountsTableFilterComposer
    extends Composer<_$PiggyDatabase, $AccountsTable> {
  $$AccountsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get ledgerId => $composableBuilder(
      column: $table.ledgerId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get type => $composableBuilder(
      column: $table.type, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get currency => $composableBuilder(
      column: $table.currency, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get initialBalance => $composableBuilder(
      column: $table.initialBalance,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get sortOrder => $composableBuilder(
      column: $table.sortOrder, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get creditLimit => $composableBuilder(
      column: $table.creditLimit, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get billingDay => $composableBuilder(
      column: $table.billingDay, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get paymentDueDay => $composableBuilder(
      column: $table.paymentDueDay, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get bankName => $composableBuilder(
      column: $table.bankName, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get cardLastFour => $composableBuilder(
      column: $table.cardLastFour, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get note => $composableBuilder(
      column: $table.note, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get syncId => $composableBuilder(
      column: $table.syncId, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get hidden => $composableBuilder(
      column: $table.hidden, builder: (column) => ColumnFilters(column));
}

class $$AccountsTableOrderingComposer
    extends Composer<_$PiggyDatabase, $AccountsTable> {
  $$AccountsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get ledgerId => $composableBuilder(
      column: $table.ledgerId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get type => $composableBuilder(
      column: $table.type, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get currency => $composableBuilder(
      column: $table.currency, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get initialBalance => $composableBuilder(
      column: $table.initialBalance,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get sortOrder => $composableBuilder(
      column: $table.sortOrder, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get creditLimit => $composableBuilder(
      column: $table.creditLimit, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get billingDay => $composableBuilder(
      column: $table.billingDay, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get paymentDueDay => $composableBuilder(
      column: $table.paymentDueDay,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get bankName => $composableBuilder(
      column: $table.bankName, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get cardLastFour => $composableBuilder(
      column: $table.cardLastFour,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get note => $composableBuilder(
      column: $table.note, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get syncId => $composableBuilder(
      column: $table.syncId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get hidden => $composableBuilder(
      column: $table.hidden, builder: (column) => ColumnOrderings(column));
}

class $$AccountsTableAnnotationComposer
    extends Composer<_$PiggyDatabase, $AccountsTable> {
  $$AccountsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get ledgerId =>
      $composableBuilder(column: $table.ledgerId, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get type =>
      $composableBuilder(column: $table.type, builder: (column) => column);

  GeneratedColumn<String> get currency =>
      $composableBuilder(column: $table.currency, builder: (column) => column);

  GeneratedColumn<double> get initialBalance => $composableBuilder(
      column: $table.initialBalance, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<int> get sortOrder =>
      $composableBuilder(column: $table.sortOrder, builder: (column) => column);

  GeneratedColumn<double> get creditLimit => $composableBuilder(
      column: $table.creditLimit, builder: (column) => column);

  GeneratedColumn<int> get billingDay => $composableBuilder(
      column: $table.billingDay, builder: (column) => column);

  GeneratedColumn<int> get paymentDueDay => $composableBuilder(
      column: $table.paymentDueDay, builder: (column) => column);

  GeneratedColumn<String> get bankName =>
      $composableBuilder(column: $table.bankName, builder: (column) => column);

  GeneratedColumn<String> get cardLastFour => $composableBuilder(
      column: $table.cardLastFour, builder: (column) => column);

  GeneratedColumn<String> get note =>
      $composableBuilder(column: $table.note, builder: (column) => column);

  GeneratedColumn<String> get syncId =>
      $composableBuilder(column: $table.syncId, builder: (column) => column);

  GeneratedColumn<bool> get hidden =>
      $composableBuilder(column: $table.hidden, builder: (column) => column);
}

class $$AccountsTableTableManager extends RootTableManager<
    _$PiggyDatabase,
    $AccountsTable,
    Account,
    $$AccountsTableFilterComposer,
    $$AccountsTableOrderingComposer,
    $$AccountsTableAnnotationComposer,
    $$AccountsTableCreateCompanionBuilder,
    $$AccountsTableUpdateCompanionBuilder,
    (Account, BaseReferences<_$PiggyDatabase, $AccountsTable, Account>),
    Account,
    PrefetchHooks Function()> {
  $$AccountsTableTableManager(_$PiggyDatabase db, $AccountsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AccountsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AccountsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AccountsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<int> ledgerId = const Value.absent(),
            Value<String> name = const Value.absent(),
            Value<String> type = const Value.absent(),
            Value<String> currency = const Value.absent(),
            Value<double> initialBalance = const Value.absent(),
            Value<DateTime?> createdAt = const Value.absent(),
            Value<DateTime?> updatedAt = const Value.absent(),
            Value<int> sortOrder = const Value.absent(),
            Value<double?> creditLimit = const Value.absent(),
            Value<int?> billingDay = const Value.absent(),
            Value<int?> paymentDueDay = const Value.absent(),
            Value<String?> bankName = const Value.absent(),
            Value<String?> cardLastFour = const Value.absent(),
            Value<String?> note = const Value.absent(),
            Value<String?> syncId = const Value.absent(),
            Value<bool> hidden = const Value.absent(),
          }) =>
              AccountsCompanion(
            id: id,
            ledgerId: ledgerId,
            name: name,
            type: type,
            currency: currency,
            initialBalance: initialBalance,
            createdAt: createdAt,
            updatedAt: updatedAt,
            sortOrder: sortOrder,
            creditLimit: creditLimit,
            billingDay: billingDay,
            paymentDueDay: paymentDueDay,
            bankName: bankName,
            cardLastFour: cardLastFour,
            note: note,
            syncId: syncId,
            hidden: hidden,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required int ledgerId,
            required String name,
            Value<String> type = const Value.absent(),
            Value<String> currency = const Value.absent(),
            Value<double> initialBalance = const Value.absent(),
            Value<DateTime?> createdAt = const Value.absent(),
            Value<DateTime?> updatedAt = const Value.absent(),
            Value<int> sortOrder = const Value.absent(),
            Value<double?> creditLimit = const Value.absent(),
            Value<int?> billingDay = const Value.absent(),
            Value<int?> paymentDueDay = const Value.absent(),
            Value<String?> bankName = const Value.absent(),
            Value<String?> cardLastFour = const Value.absent(),
            Value<String?> note = const Value.absent(),
            Value<String?> syncId = const Value.absent(),
            Value<bool> hidden = const Value.absent(),
          }) =>
              AccountsCompanion.insert(
            id: id,
            ledgerId: ledgerId,
            name: name,
            type: type,
            currency: currency,
            initialBalance: initialBalance,
            createdAt: createdAt,
            updatedAt: updatedAt,
            sortOrder: sortOrder,
            creditLimit: creditLimit,
            billingDay: billingDay,
            paymentDueDay: paymentDueDay,
            bankName: bankName,
            cardLastFour: cardLastFour,
            note: note,
            syncId: syncId,
            hidden: hidden,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable<$AccountsTable, Account>(table),
                    BaseReferences<_$PiggyDatabase, $AccountsTable, Account>(
                        db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$AccountsTableProcessedTableManager = ProcessedTableManager<
    _$PiggyDatabase,
    $AccountsTable,
    Account,
    $$AccountsTableFilterComposer,
    $$AccountsTableOrderingComposer,
    $$AccountsTableAnnotationComposer,
    $$AccountsTableCreateCompanionBuilder,
    $$AccountsTableUpdateCompanionBuilder,
    (Account, BaseReferences<_$PiggyDatabase, $AccountsTable, Account>),
    Account,
    PrefetchHooks Function()>;
typedef $$HoldingsTableCreateCompanionBuilder = HoldingsCompanion Function({
  Value<int> id,
  Value<int> ledgerId,
  required int accountId,
  required String name,
  Value<String?> symbol,
  Value<String?> market,
  Value<String> assetClass,
  Value<String> currency,
  Value<double> quantity,
  Value<double> unitCost,
  Value<double> unitPrice,
  Value<bool> autoQuote,
  Value<String?> note,
  Value<int> sortOrder,
  Value<String?> syncId,
  Value<DateTime?> createdAt,
  Value<DateTime?> updatedAt,
  Value<double?> quotePrice,
  Value<DateTime?> quoteFetchedAt,
  Value<String?> quoteSourceId,
});
typedef $$HoldingsTableUpdateCompanionBuilder = HoldingsCompanion Function({
  Value<int> id,
  Value<int> ledgerId,
  Value<int> accountId,
  Value<String> name,
  Value<String?> symbol,
  Value<String?> market,
  Value<String> assetClass,
  Value<String> currency,
  Value<double> quantity,
  Value<double> unitCost,
  Value<double> unitPrice,
  Value<bool> autoQuote,
  Value<String?> note,
  Value<int> sortOrder,
  Value<String?> syncId,
  Value<DateTime?> createdAt,
  Value<DateTime?> updatedAt,
  Value<double?> quotePrice,
  Value<DateTime?> quoteFetchedAt,
  Value<String?> quoteSourceId,
});

class $$HoldingsTableFilterComposer
    extends Composer<_$PiggyDatabase, $HoldingsTable> {
  $$HoldingsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get ledgerId => $composableBuilder(
      column: $table.ledgerId, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get accountId => $composableBuilder(
      column: $table.accountId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get symbol => $composableBuilder(
      column: $table.symbol, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get market => $composableBuilder(
      column: $table.market, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get assetClass => $composableBuilder(
      column: $table.assetClass, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get currency => $composableBuilder(
      column: $table.currency, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get quantity => $composableBuilder(
      column: $table.quantity, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get unitCost => $composableBuilder(
      column: $table.unitCost, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get unitPrice => $composableBuilder(
      column: $table.unitPrice, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get autoQuote => $composableBuilder(
      column: $table.autoQuote, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get note => $composableBuilder(
      column: $table.note, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get sortOrder => $composableBuilder(
      column: $table.sortOrder, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get syncId => $composableBuilder(
      column: $table.syncId, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get quotePrice => $composableBuilder(
      column: $table.quotePrice, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get quoteFetchedAt => $composableBuilder(
      column: $table.quoteFetchedAt,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get quoteSourceId => $composableBuilder(
      column: $table.quoteSourceId, builder: (column) => ColumnFilters(column));
}

class $$HoldingsTableOrderingComposer
    extends Composer<_$PiggyDatabase, $HoldingsTable> {
  $$HoldingsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get ledgerId => $composableBuilder(
      column: $table.ledgerId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get accountId => $composableBuilder(
      column: $table.accountId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get symbol => $composableBuilder(
      column: $table.symbol, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get market => $composableBuilder(
      column: $table.market, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get assetClass => $composableBuilder(
      column: $table.assetClass, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get currency => $composableBuilder(
      column: $table.currency, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get quantity => $composableBuilder(
      column: $table.quantity, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get unitCost => $composableBuilder(
      column: $table.unitCost, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get unitPrice => $composableBuilder(
      column: $table.unitPrice, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get autoQuote => $composableBuilder(
      column: $table.autoQuote, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get note => $composableBuilder(
      column: $table.note, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get sortOrder => $composableBuilder(
      column: $table.sortOrder, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get syncId => $composableBuilder(
      column: $table.syncId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get quotePrice => $composableBuilder(
      column: $table.quotePrice, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get quoteFetchedAt => $composableBuilder(
      column: $table.quoteFetchedAt,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get quoteSourceId => $composableBuilder(
      column: $table.quoteSourceId,
      builder: (column) => ColumnOrderings(column));
}

class $$HoldingsTableAnnotationComposer
    extends Composer<_$PiggyDatabase, $HoldingsTable> {
  $$HoldingsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get ledgerId =>
      $composableBuilder(column: $table.ledgerId, builder: (column) => column);

  GeneratedColumn<int> get accountId =>
      $composableBuilder(column: $table.accountId, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get symbol =>
      $composableBuilder(column: $table.symbol, builder: (column) => column);

  GeneratedColumn<String> get market =>
      $composableBuilder(column: $table.market, builder: (column) => column);

  GeneratedColumn<String> get assetClass => $composableBuilder(
      column: $table.assetClass, builder: (column) => column);

  GeneratedColumn<String> get currency =>
      $composableBuilder(column: $table.currency, builder: (column) => column);

  GeneratedColumn<double> get quantity =>
      $composableBuilder(column: $table.quantity, builder: (column) => column);

  GeneratedColumn<double> get unitCost =>
      $composableBuilder(column: $table.unitCost, builder: (column) => column);

  GeneratedColumn<double> get unitPrice =>
      $composableBuilder(column: $table.unitPrice, builder: (column) => column);

  GeneratedColumn<bool> get autoQuote =>
      $composableBuilder(column: $table.autoQuote, builder: (column) => column);

  GeneratedColumn<String> get note =>
      $composableBuilder(column: $table.note, builder: (column) => column);

  GeneratedColumn<int> get sortOrder =>
      $composableBuilder(column: $table.sortOrder, builder: (column) => column);

  GeneratedColumn<String> get syncId =>
      $composableBuilder(column: $table.syncId, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<double> get quotePrice => $composableBuilder(
      column: $table.quotePrice, builder: (column) => column);

  GeneratedColumn<DateTime> get quoteFetchedAt => $composableBuilder(
      column: $table.quoteFetchedAt, builder: (column) => column);

  GeneratedColumn<String> get quoteSourceId => $composableBuilder(
      column: $table.quoteSourceId, builder: (column) => column);
}

class $$HoldingsTableTableManager extends RootTableManager<
    _$PiggyDatabase,
    $HoldingsTable,
    Holding,
    $$HoldingsTableFilterComposer,
    $$HoldingsTableOrderingComposer,
    $$HoldingsTableAnnotationComposer,
    $$HoldingsTableCreateCompanionBuilder,
    $$HoldingsTableUpdateCompanionBuilder,
    (Holding, BaseReferences<_$PiggyDatabase, $HoldingsTable, Holding>),
    Holding,
    PrefetchHooks Function()> {
  $$HoldingsTableTableManager(_$PiggyDatabase db, $HoldingsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$HoldingsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$HoldingsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$HoldingsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<int> ledgerId = const Value.absent(),
            Value<int> accountId = const Value.absent(),
            Value<String> name = const Value.absent(),
            Value<String?> symbol = const Value.absent(),
            Value<String?> market = const Value.absent(),
            Value<String> assetClass = const Value.absent(),
            Value<String> currency = const Value.absent(),
            Value<double> quantity = const Value.absent(),
            Value<double> unitCost = const Value.absent(),
            Value<double> unitPrice = const Value.absent(),
            Value<bool> autoQuote = const Value.absent(),
            Value<String?> note = const Value.absent(),
            Value<int> sortOrder = const Value.absent(),
            Value<String?> syncId = const Value.absent(),
            Value<DateTime?> createdAt = const Value.absent(),
            Value<DateTime?> updatedAt = const Value.absent(),
            Value<double?> quotePrice = const Value.absent(),
            Value<DateTime?> quoteFetchedAt = const Value.absent(),
            Value<String?> quoteSourceId = const Value.absent(),
          }) =>
              HoldingsCompanion(
            id: id,
            ledgerId: ledgerId,
            accountId: accountId,
            name: name,
            symbol: symbol,
            market: market,
            assetClass: assetClass,
            currency: currency,
            quantity: quantity,
            unitCost: unitCost,
            unitPrice: unitPrice,
            autoQuote: autoQuote,
            note: note,
            sortOrder: sortOrder,
            syncId: syncId,
            createdAt: createdAt,
            updatedAt: updatedAt,
            quotePrice: quotePrice,
            quoteFetchedAt: quoteFetchedAt,
            quoteSourceId: quoteSourceId,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<int> ledgerId = const Value.absent(),
            required int accountId,
            required String name,
            Value<String?> symbol = const Value.absent(),
            Value<String?> market = const Value.absent(),
            Value<String> assetClass = const Value.absent(),
            Value<String> currency = const Value.absent(),
            Value<double> quantity = const Value.absent(),
            Value<double> unitCost = const Value.absent(),
            Value<double> unitPrice = const Value.absent(),
            Value<bool> autoQuote = const Value.absent(),
            Value<String?> note = const Value.absent(),
            Value<int> sortOrder = const Value.absent(),
            Value<String?> syncId = const Value.absent(),
            Value<DateTime?> createdAt = const Value.absent(),
            Value<DateTime?> updatedAt = const Value.absent(),
            Value<double?> quotePrice = const Value.absent(),
            Value<DateTime?> quoteFetchedAt = const Value.absent(),
            Value<String?> quoteSourceId = const Value.absent(),
          }) =>
              HoldingsCompanion.insert(
            id: id,
            ledgerId: ledgerId,
            accountId: accountId,
            name: name,
            symbol: symbol,
            market: market,
            assetClass: assetClass,
            currency: currency,
            quantity: quantity,
            unitCost: unitCost,
            unitPrice: unitPrice,
            autoQuote: autoQuote,
            note: note,
            sortOrder: sortOrder,
            syncId: syncId,
            createdAt: createdAt,
            updatedAt: updatedAt,
            quotePrice: quotePrice,
            quoteFetchedAt: quoteFetchedAt,
            quoteSourceId: quoteSourceId,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable<$HoldingsTable, Holding>(table),
                    BaseReferences<_$PiggyDatabase, $HoldingsTable, Holding>(
                        db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$HoldingsTableProcessedTableManager = ProcessedTableManager<
    _$PiggyDatabase,
    $HoldingsTable,
    Holding,
    $$HoldingsTableFilterComposer,
    $$HoldingsTableOrderingComposer,
    $$HoldingsTableAnnotationComposer,
    $$HoldingsTableCreateCompanionBuilder,
    $$HoldingsTableUpdateCompanionBuilder,
    (Holding, BaseReferences<_$PiggyDatabase, $HoldingsTable, Holding>),
    Holding,
    PrefetchHooks Function()>;
typedef $$CategoriesTableCreateCompanionBuilder = CategoriesCompanion Function({
  Value<int> id,
  required String name,
  required String kind,
  Value<String?> icon,
  Value<int> sortOrder,
  Value<int?> parentId,
  Value<int> level,
  Value<String> iconType,
  Value<String?> customIconPath,
  Value<String?> communityIconId,
  Value<String?> syncId,
  Value<DateTime?> updatedAt,
});
typedef $$CategoriesTableUpdateCompanionBuilder = CategoriesCompanion Function({
  Value<int> id,
  Value<String> name,
  Value<String> kind,
  Value<String?> icon,
  Value<int> sortOrder,
  Value<int?> parentId,
  Value<int> level,
  Value<String> iconType,
  Value<String?> customIconPath,
  Value<String?> communityIconId,
  Value<String?> syncId,
  Value<DateTime?> updatedAt,
});

class $$CategoriesTableFilterComposer
    extends Composer<_$PiggyDatabase, $CategoriesTable> {
  $$CategoriesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get kind => $composableBuilder(
      column: $table.kind, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get icon => $composableBuilder(
      column: $table.icon, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get sortOrder => $composableBuilder(
      column: $table.sortOrder, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get parentId => $composableBuilder(
      column: $table.parentId, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get level => $composableBuilder(
      column: $table.level, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get iconType => $composableBuilder(
      column: $table.iconType, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get customIconPath => $composableBuilder(
      column: $table.customIconPath,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get communityIconId => $composableBuilder(
      column: $table.communityIconId,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get syncId => $composableBuilder(
      column: $table.syncId, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnFilters(column));
}

class $$CategoriesTableOrderingComposer
    extends Composer<_$PiggyDatabase, $CategoriesTable> {
  $$CategoriesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get kind => $composableBuilder(
      column: $table.kind, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get icon => $composableBuilder(
      column: $table.icon, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get sortOrder => $composableBuilder(
      column: $table.sortOrder, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get parentId => $composableBuilder(
      column: $table.parentId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get level => $composableBuilder(
      column: $table.level, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get iconType => $composableBuilder(
      column: $table.iconType, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get customIconPath => $composableBuilder(
      column: $table.customIconPath,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get communityIconId => $composableBuilder(
      column: $table.communityIconId,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get syncId => $composableBuilder(
      column: $table.syncId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnOrderings(column));
}

class $$CategoriesTableAnnotationComposer
    extends Composer<_$PiggyDatabase, $CategoriesTable> {
  $$CategoriesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => column);

  GeneratedColumn<String> get icon =>
      $composableBuilder(column: $table.icon, builder: (column) => column);

  GeneratedColumn<int> get sortOrder =>
      $composableBuilder(column: $table.sortOrder, builder: (column) => column);

  GeneratedColumn<int> get parentId =>
      $composableBuilder(column: $table.parentId, builder: (column) => column);

  GeneratedColumn<int> get level =>
      $composableBuilder(column: $table.level, builder: (column) => column);

  GeneratedColumn<String> get iconType =>
      $composableBuilder(column: $table.iconType, builder: (column) => column);

  GeneratedColumn<String> get customIconPath => $composableBuilder(
      column: $table.customIconPath, builder: (column) => column);

  GeneratedColumn<String> get communityIconId => $composableBuilder(
      column: $table.communityIconId, builder: (column) => column);

  GeneratedColumn<String> get syncId =>
      $composableBuilder(column: $table.syncId, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$CategoriesTableTableManager extends RootTableManager<
    _$PiggyDatabase,
    $CategoriesTable,
    Category,
    $$CategoriesTableFilterComposer,
    $$CategoriesTableOrderingComposer,
    $$CategoriesTableAnnotationComposer,
    $$CategoriesTableCreateCompanionBuilder,
    $$CategoriesTableUpdateCompanionBuilder,
    (Category, BaseReferences<_$PiggyDatabase, $CategoriesTable, Category>),
    Category,
    PrefetchHooks Function()> {
  $$CategoriesTableTableManager(_$PiggyDatabase db, $CategoriesTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CategoriesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$CategoriesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$CategoriesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> name = const Value.absent(),
            Value<String> kind = const Value.absent(),
            Value<String?> icon = const Value.absent(),
            Value<int> sortOrder = const Value.absent(),
            Value<int?> parentId = const Value.absent(),
            Value<int> level = const Value.absent(),
            Value<String> iconType = const Value.absent(),
            Value<String?> customIconPath = const Value.absent(),
            Value<String?> communityIconId = const Value.absent(),
            Value<String?> syncId = const Value.absent(),
            Value<DateTime?> updatedAt = const Value.absent(),
          }) =>
              CategoriesCompanion(
            id: id,
            name: name,
            kind: kind,
            icon: icon,
            sortOrder: sortOrder,
            parentId: parentId,
            level: level,
            iconType: iconType,
            customIconPath: customIconPath,
            communityIconId: communityIconId,
            syncId: syncId,
            updatedAt: updatedAt,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required String name,
            required String kind,
            Value<String?> icon = const Value.absent(),
            Value<int> sortOrder = const Value.absent(),
            Value<int?> parentId = const Value.absent(),
            Value<int> level = const Value.absent(),
            Value<String> iconType = const Value.absent(),
            Value<String?> customIconPath = const Value.absent(),
            Value<String?> communityIconId = const Value.absent(),
            Value<String?> syncId = const Value.absent(),
            Value<DateTime?> updatedAt = const Value.absent(),
          }) =>
              CategoriesCompanion.insert(
            id: id,
            name: name,
            kind: kind,
            icon: icon,
            sortOrder: sortOrder,
            parentId: parentId,
            level: level,
            iconType: iconType,
            customIconPath: customIconPath,
            communityIconId: communityIconId,
            syncId: syncId,
            updatedAt: updatedAt,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable<$CategoriesTable, Category>(table),
                    BaseReferences<_$PiggyDatabase, $CategoriesTable, Category>(
                        db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$CategoriesTableProcessedTableManager = ProcessedTableManager<
    _$PiggyDatabase,
    $CategoriesTable,
    Category,
    $$CategoriesTableFilterComposer,
    $$CategoriesTableOrderingComposer,
    $$CategoriesTableAnnotationComposer,
    $$CategoriesTableCreateCompanionBuilder,
    $$CategoriesTableUpdateCompanionBuilder,
    (Category, BaseReferences<_$PiggyDatabase, $CategoriesTable, Category>),
    Category,
    PrefetchHooks Function()>;
typedef $$TransactionsTableCreateCompanionBuilder = TransactionsCompanion
    Function({
  Value<int> id,
  required int ledgerId,
  required String type,
  required double amount,
  Value<int?> categoryId,
  Value<int?> accountId,
  Value<int?> toAccountId,
  Value<DateTime> happenedAt,
  Value<String?> note,
  Value<int?> recurringId,
  Value<String?> syncId,
  Value<String?> createdByUserId,
  Value<String?> lastEditedByUserId,
  Value<bool> excludeFromStats,
  Value<bool> excludeFromBudget,
  Value<DateTime?> updatedAt,
  Value<String?> currencyCode,
  Value<double?> nativeAmount,
  Value<double?> originalAmount,
  Value<String?> customValuesJson,
});
typedef $$TransactionsTableUpdateCompanionBuilder = TransactionsCompanion
    Function({
  Value<int> id,
  Value<int> ledgerId,
  Value<String> type,
  Value<double> amount,
  Value<int?> categoryId,
  Value<int?> accountId,
  Value<int?> toAccountId,
  Value<DateTime> happenedAt,
  Value<String?> note,
  Value<int?> recurringId,
  Value<String?> syncId,
  Value<String?> createdByUserId,
  Value<String?> lastEditedByUserId,
  Value<bool> excludeFromStats,
  Value<bool> excludeFromBudget,
  Value<DateTime?> updatedAt,
  Value<String?> currencyCode,
  Value<double?> nativeAmount,
  Value<double?> originalAmount,
  Value<String?> customValuesJson,
});

class $$TransactionsTableFilterComposer
    extends Composer<_$PiggyDatabase, $TransactionsTable> {
  $$TransactionsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get ledgerId => $composableBuilder(
      column: $table.ledgerId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get type => $composableBuilder(
      column: $table.type, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get amount => $composableBuilder(
      column: $table.amount, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get categoryId => $composableBuilder(
      column: $table.categoryId, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get accountId => $composableBuilder(
      column: $table.accountId, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get toAccountId => $composableBuilder(
      column: $table.toAccountId, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get happenedAt => $composableBuilder(
      column: $table.happenedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get note => $composableBuilder(
      column: $table.note, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get recurringId => $composableBuilder(
      column: $table.recurringId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get syncId => $composableBuilder(
      column: $table.syncId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get createdByUserId => $composableBuilder(
      column: $table.createdByUserId,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get lastEditedByUserId => $composableBuilder(
      column: $table.lastEditedByUserId,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get excludeFromStats => $composableBuilder(
      column: $table.excludeFromStats,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get excludeFromBudget => $composableBuilder(
      column: $table.excludeFromBudget,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get currencyCode => $composableBuilder(
      column: $table.currencyCode, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get nativeAmount => $composableBuilder(
      column: $table.nativeAmount, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get originalAmount => $composableBuilder(
      column: $table.originalAmount,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get customValuesJson => $composableBuilder(
      column: $table.customValuesJson,
      builder: (column) => ColumnFilters(column));
}

class $$TransactionsTableOrderingComposer
    extends Composer<_$PiggyDatabase, $TransactionsTable> {
  $$TransactionsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get ledgerId => $composableBuilder(
      column: $table.ledgerId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get type => $composableBuilder(
      column: $table.type, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get amount => $composableBuilder(
      column: $table.amount, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get categoryId => $composableBuilder(
      column: $table.categoryId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get accountId => $composableBuilder(
      column: $table.accountId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get toAccountId => $composableBuilder(
      column: $table.toAccountId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get happenedAt => $composableBuilder(
      column: $table.happenedAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get note => $composableBuilder(
      column: $table.note, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get recurringId => $composableBuilder(
      column: $table.recurringId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get syncId => $composableBuilder(
      column: $table.syncId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get createdByUserId => $composableBuilder(
      column: $table.createdByUserId,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get lastEditedByUserId => $composableBuilder(
      column: $table.lastEditedByUserId,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get excludeFromStats => $composableBuilder(
      column: $table.excludeFromStats,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get excludeFromBudget => $composableBuilder(
      column: $table.excludeFromBudget,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get currencyCode => $composableBuilder(
      column: $table.currencyCode,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get nativeAmount => $composableBuilder(
      column: $table.nativeAmount,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get originalAmount => $composableBuilder(
      column: $table.originalAmount,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get customValuesJson => $composableBuilder(
      column: $table.customValuesJson,
      builder: (column) => ColumnOrderings(column));
}

class $$TransactionsTableAnnotationComposer
    extends Composer<_$PiggyDatabase, $TransactionsTable> {
  $$TransactionsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get ledgerId =>
      $composableBuilder(column: $table.ledgerId, builder: (column) => column);

  GeneratedColumn<String> get type =>
      $composableBuilder(column: $table.type, builder: (column) => column);

  GeneratedColumn<double> get amount =>
      $composableBuilder(column: $table.amount, builder: (column) => column);

  GeneratedColumn<int> get categoryId => $composableBuilder(
      column: $table.categoryId, builder: (column) => column);

  GeneratedColumn<int> get accountId =>
      $composableBuilder(column: $table.accountId, builder: (column) => column);

  GeneratedColumn<int> get toAccountId => $composableBuilder(
      column: $table.toAccountId, builder: (column) => column);

  GeneratedColumn<DateTime> get happenedAt => $composableBuilder(
      column: $table.happenedAt, builder: (column) => column);

  GeneratedColumn<String> get note =>
      $composableBuilder(column: $table.note, builder: (column) => column);

  GeneratedColumn<int> get recurringId => $composableBuilder(
      column: $table.recurringId, builder: (column) => column);

  GeneratedColumn<String> get syncId =>
      $composableBuilder(column: $table.syncId, builder: (column) => column);

  GeneratedColumn<String> get createdByUserId => $composableBuilder(
      column: $table.createdByUserId, builder: (column) => column);

  GeneratedColumn<String> get lastEditedByUserId => $composableBuilder(
      column: $table.lastEditedByUserId, builder: (column) => column);

  GeneratedColumn<bool> get excludeFromStats => $composableBuilder(
      column: $table.excludeFromStats, builder: (column) => column);

  GeneratedColumn<bool> get excludeFromBudget => $composableBuilder(
      column: $table.excludeFromBudget, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<String> get currencyCode => $composableBuilder(
      column: $table.currencyCode, builder: (column) => column);

  GeneratedColumn<double> get nativeAmount => $composableBuilder(
      column: $table.nativeAmount, builder: (column) => column);

  GeneratedColumn<double> get originalAmount => $composableBuilder(
      column: $table.originalAmount, builder: (column) => column);

  GeneratedColumn<String> get customValuesJson => $composableBuilder(
      column: $table.customValuesJson, builder: (column) => column);
}

class $$TransactionsTableTableManager extends RootTableManager<
    _$PiggyDatabase,
    $TransactionsTable,
    Transaction,
    $$TransactionsTableFilterComposer,
    $$TransactionsTableOrderingComposer,
    $$TransactionsTableAnnotationComposer,
    $$TransactionsTableCreateCompanionBuilder,
    $$TransactionsTableUpdateCompanionBuilder,
    (
      Transaction,
      BaseReferences<_$PiggyDatabase, $TransactionsTable, Transaction>
    ),
    Transaction,
    PrefetchHooks Function()> {
  $$TransactionsTableTableManager(_$PiggyDatabase db, $TransactionsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$TransactionsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$TransactionsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$TransactionsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<int> ledgerId = const Value.absent(),
            Value<String> type = const Value.absent(),
            Value<double> amount = const Value.absent(),
            Value<int?> categoryId = const Value.absent(),
            Value<int?> accountId = const Value.absent(),
            Value<int?> toAccountId = const Value.absent(),
            Value<DateTime> happenedAt = const Value.absent(),
            Value<String?> note = const Value.absent(),
            Value<int?> recurringId = const Value.absent(),
            Value<String?> syncId = const Value.absent(),
            Value<String?> createdByUserId = const Value.absent(),
            Value<String?> lastEditedByUserId = const Value.absent(),
            Value<bool> excludeFromStats = const Value.absent(),
            Value<bool> excludeFromBudget = const Value.absent(),
            Value<DateTime?> updatedAt = const Value.absent(),
            Value<String?> currencyCode = const Value.absent(),
            Value<double?> nativeAmount = const Value.absent(),
            Value<double?> originalAmount = const Value.absent(),
            Value<String?> customValuesJson = const Value.absent(),
          }) =>
              TransactionsCompanion(
            id: id,
            ledgerId: ledgerId,
            type: type,
            amount: amount,
            categoryId: categoryId,
            accountId: accountId,
            toAccountId: toAccountId,
            happenedAt: happenedAt,
            note: note,
            recurringId: recurringId,
            syncId: syncId,
            createdByUserId: createdByUserId,
            lastEditedByUserId: lastEditedByUserId,
            excludeFromStats: excludeFromStats,
            excludeFromBudget: excludeFromBudget,
            updatedAt: updatedAt,
            currencyCode: currencyCode,
            nativeAmount: nativeAmount,
            originalAmount: originalAmount,
            customValuesJson: customValuesJson,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required int ledgerId,
            required String type,
            required double amount,
            Value<int?> categoryId = const Value.absent(),
            Value<int?> accountId = const Value.absent(),
            Value<int?> toAccountId = const Value.absent(),
            Value<DateTime> happenedAt = const Value.absent(),
            Value<String?> note = const Value.absent(),
            Value<int?> recurringId = const Value.absent(),
            Value<String?> syncId = const Value.absent(),
            Value<String?> createdByUserId = const Value.absent(),
            Value<String?> lastEditedByUserId = const Value.absent(),
            Value<bool> excludeFromStats = const Value.absent(),
            Value<bool> excludeFromBudget = const Value.absent(),
            Value<DateTime?> updatedAt = const Value.absent(),
            Value<String?> currencyCode = const Value.absent(),
            Value<double?> nativeAmount = const Value.absent(),
            Value<double?> originalAmount = const Value.absent(),
            Value<String?> customValuesJson = const Value.absent(),
          }) =>
              TransactionsCompanion.insert(
            id: id,
            ledgerId: ledgerId,
            type: type,
            amount: amount,
            categoryId: categoryId,
            accountId: accountId,
            toAccountId: toAccountId,
            happenedAt: happenedAt,
            note: note,
            recurringId: recurringId,
            syncId: syncId,
            createdByUserId: createdByUserId,
            lastEditedByUserId: lastEditedByUserId,
            excludeFromStats: excludeFromStats,
            excludeFromBudget: excludeFromBudget,
            updatedAt: updatedAt,
            currencyCode: currencyCode,
            nativeAmount: nativeAmount,
            originalAmount: originalAmount,
            customValuesJson: customValuesJson,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable<$TransactionsTable, Transaction>(table),
                    BaseReferences<_$PiggyDatabase, $TransactionsTable,
                        Transaction>(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$TransactionsTableProcessedTableManager = ProcessedTableManager<
    _$PiggyDatabase,
    $TransactionsTable,
    Transaction,
    $$TransactionsTableFilterComposer,
    $$TransactionsTableOrderingComposer,
    $$TransactionsTableAnnotationComposer,
    $$TransactionsTableCreateCompanionBuilder,
    $$TransactionsTableUpdateCompanionBuilder,
    (
      Transaction,
      BaseReferences<_$PiggyDatabase, $TransactionsTable, Transaction>
    ),
    Transaction,
    PrefetchHooks Function()>;
typedef $$RecurringTransactionsTableCreateCompanionBuilder
    = RecurringTransactionsCompanion Function({
  Value<int> id,
  required int ledgerId,
  Value<String?> syncId,
  required String type,
  required double amount,
  Value<int?> categoryId,
  Value<int?> accountId,
  Value<int?> toAccountId,
  Value<String?> note,
  required String frequency,
  Value<int> interval,
  Value<int?> dayOfMonth,
  Value<int?> dayOfWeek,
  Value<int?> monthOfYear,
  required DateTime startDate,
  Value<DateTime?> endDate,
  Value<DateTime?> lastGeneratedDate,
  Value<bool> enabled,
  Value<String?> currencyCode,
  Value<String?> templateFieldValues,
  Value<DateTime> createdAt,
  Value<DateTime> updatedAt,
});
typedef $$RecurringTransactionsTableUpdateCompanionBuilder
    = RecurringTransactionsCompanion Function({
  Value<int> id,
  Value<int> ledgerId,
  Value<String?> syncId,
  Value<String> type,
  Value<double> amount,
  Value<int?> categoryId,
  Value<int?> accountId,
  Value<int?> toAccountId,
  Value<String?> note,
  Value<String> frequency,
  Value<int> interval,
  Value<int?> dayOfMonth,
  Value<int?> dayOfWeek,
  Value<int?> monthOfYear,
  Value<DateTime> startDate,
  Value<DateTime?> endDate,
  Value<DateTime?> lastGeneratedDate,
  Value<bool> enabled,
  Value<String?> currencyCode,
  Value<String?> templateFieldValues,
  Value<DateTime> createdAt,
  Value<DateTime> updatedAt,
});

class $$RecurringTransactionsTableFilterComposer
    extends Composer<_$PiggyDatabase, $RecurringTransactionsTable> {
  $$RecurringTransactionsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get ledgerId => $composableBuilder(
      column: $table.ledgerId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get syncId => $composableBuilder(
      column: $table.syncId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get type => $composableBuilder(
      column: $table.type, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get amount => $composableBuilder(
      column: $table.amount, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get categoryId => $composableBuilder(
      column: $table.categoryId, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get accountId => $composableBuilder(
      column: $table.accountId, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get toAccountId => $composableBuilder(
      column: $table.toAccountId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get note => $composableBuilder(
      column: $table.note, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get frequency => $composableBuilder(
      column: $table.frequency, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get interval => $composableBuilder(
      column: $table.interval, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get dayOfMonth => $composableBuilder(
      column: $table.dayOfMonth, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get dayOfWeek => $composableBuilder(
      column: $table.dayOfWeek, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get monthOfYear => $composableBuilder(
      column: $table.monthOfYear, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get startDate => $composableBuilder(
      column: $table.startDate, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get endDate => $composableBuilder(
      column: $table.endDate, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get lastGeneratedDate => $composableBuilder(
      column: $table.lastGeneratedDate,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get enabled => $composableBuilder(
      column: $table.enabled, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get currencyCode => $composableBuilder(
      column: $table.currencyCode, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get templateFieldValues => $composableBuilder(
      column: $table.templateFieldValues,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnFilters(column));
}

class $$RecurringTransactionsTableOrderingComposer
    extends Composer<_$PiggyDatabase, $RecurringTransactionsTable> {
  $$RecurringTransactionsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get ledgerId => $composableBuilder(
      column: $table.ledgerId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get syncId => $composableBuilder(
      column: $table.syncId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get type => $composableBuilder(
      column: $table.type, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get amount => $composableBuilder(
      column: $table.amount, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get categoryId => $composableBuilder(
      column: $table.categoryId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get accountId => $composableBuilder(
      column: $table.accountId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get toAccountId => $composableBuilder(
      column: $table.toAccountId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get note => $composableBuilder(
      column: $table.note, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get frequency => $composableBuilder(
      column: $table.frequency, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get interval => $composableBuilder(
      column: $table.interval, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get dayOfMonth => $composableBuilder(
      column: $table.dayOfMonth, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get dayOfWeek => $composableBuilder(
      column: $table.dayOfWeek, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get monthOfYear => $composableBuilder(
      column: $table.monthOfYear, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get startDate => $composableBuilder(
      column: $table.startDate, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get endDate => $composableBuilder(
      column: $table.endDate, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get lastGeneratedDate => $composableBuilder(
      column: $table.lastGeneratedDate,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get enabled => $composableBuilder(
      column: $table.enabled, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get currencyCode => $composableBuilder(
      column: $table.currencyCode,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get templateFieldValues => $composableBuilder(
      column: $table.templateFieldValues,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnOrderings(column));
}

class $$RecurringTransactionsTableAnnotationComposer
    extends Composer<_$PiggyDatabase, $RecurringTransactionsTable> {
  $$RecurringTransactionsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get ledgerId =>
      $composableBuilder(column: $table.ledgerId, builder: (column) => column);

  GeneratedColumn<String> get syncId =>
      $composableBuilder(column: $table.syncId, builder: (column) => column);

  GeneratedColumn<String> get type =>
      $composableBuilder(column: $table.type, builder: (column) => column);

  GeneratedColumn<double> get amount =>
      $composableBuilder(column: $table.amount, builder: (column) => column);

  GeneratedColumn<int> get categoryId => $composableBuilder(
      column: $table.categoryId, builder: (column) => column);

  GeneratedColumn<int> get accountId =>
      $composableBuilder(column: $table.accountId, builder: (column) => column);

  GeneratedColumn<int> get toAccountId => $composableBuilder(
      column: $table.toAccountId, builder: (column) => column);

  GeneratedColumn<String> get note =>
      $composableBuilder(column: $table.note, builder: (column) => column);

  GeneratedColumn<String> get frequency =>
      $composableBuilder(column: $table.frequency, builder: (column) => column);

  GeneratedColumn<int> get interval =>
      $composableBuilder(column: $table.interval, builder: (column) => column);

  GeneratedColumn<int> get dayOfMonth => $composableBuilder(
      column: $table.dayOfMonth, builder: (column) => column);

  GeneratedColumn<int> get dayOfWeek =>
      $composableBuilder(column: $table.dayOfWeek, builder: (column) => column);

  GeneratedColumn<int> get monthOfYear => $composableBuilder(
      column: $table.monthOfYear, builder: (column) => column);

  GeneratedColumn<DateTime> get startDate =>
      $composableBuilder(column: $table.startDate, builder: (column) => column);

  GeneratedColumn<DateTime> get endDate =>
      $composableBuilder(column: $table.endDate, builder: (column) => column);

  GeneratedColumn<DateTime> get lastGeneratedDate => $composableBuilder(
      column: $table.lastGeneratedDate, builder: (column) => column);

  GeneratedColumn<bool> get enabled =>
      $composableBuilder(column: $table.enabled, builder: (column) => column);

  GeneratedColumn<String> get currencyCode => $composableBuilder(
      column: $table.currencyCode, builder: (column) => column);

  GeneratedColumn<String> get templateFieldValues => $composableBuilder(
      column: $table.templateFieldValues, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$RecurringTransactionsTableTableManager extends RootTableManager<
    _$PiggyDatabase,
    $RecurringTransactionsTable,
    RecurringTransaction,
    $$RecurringTransactionsTableFilterComposer,
    $$RecurringTransactionsTableOrderingComposer,
    $$RecurringTransactionsTableAnnotationComposer,
    $$RecurringTransactionsTableCreateCompanionBuilder,
    $$RecurringTransactionsTableUpdateCompanionBuilder,
    (
      RecurringTransaction,
      BaseReferences<_$PiggyDatabase, $RecurringTransactionsTable,
          RecurringTransaction>
    ),
    RecurringTransaction,
    PrefetchHooks Function()> {
  $$RecurringTransactionsTableTableManager(
      _$PiggyDatabase db, $RecurringTransactionsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$RecurringTransactionsTableFilterComposer(
                  $db: db, $table: table),
          createOrderingComposer: () =>
              $$RecurringTransactionsTableOrderingComposer(
                  $db: db, $table: table),
          createComputedFieldComposer: () =>
              $$RecurringTransactionsTableAnnotationComposer(
                  $db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<int> ledgerId = const Value.absent(),
            Value<String?> syncId = const Value.absent(),
            Value<String> type = const Value.absent(),
            Value<double> amount = const Value.absent(),
            Value<int?> categoryId = const Value.absent(),
            Value<int?> accountId = const Value.absent(),
            Value<int?> toAccountId = const Value.absent(),
            Value<String?> note = const Value.absent(),
            Value<String> frequency = const Value.absent(),
            Value<int> interval = const Value.absent(),
            Value<int?> dayOfMonth = const Value.absent(),
            Value<int?> dayOfWeek = const Value.absent(),
            Value<int?> monthOfYear = const Value.absent(),
            Value<DateTime> startDate = const Value.absent(),
            Value<DateTime?> endDate = const Value.absent(),
            Value<DateTime?> lastGeneratedDate = const Value.absent(),
            Value<bool> enabled = const Value.absent(),
            Value<String?> currencyCode = const Value.absent(),
            Value<String?> templateFieldValues = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
            Value<DateTime> updatedAt = const Value.absent(),
          }) =>
              RecurringTransactionsCompanion(
            id: id,
            ledgerId: ledgerId,
            syncId: syncId,
            type: type,
            amount: amount,
            categoryId: categoryId,
            accountId: accountId,
            toAccountId: toAccountId,
            note: note,
            frequency: frequency,
            interval: interval,
            dayOfMonth: dayOfMonth,
            dayOfWeek: dayOfWeek,
            monthOfYear: monthOfYear,
            startDate: startDate,
            endDate: endDate,
            lastGeneratedDate: lastGeneratedDate,
            enabled: enabled,
            currencyCode: currencyCode,
            templateFieldValues: templateFieldValues,
            createdAt: createdAt,
            updatedAt: updatedAt,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required int ledgerId,
            Value<String?> syncId = const Value.absent(),
            required String type,
            required double amount,
            Value<int?> categoryId = const Value.absent(),
            Value<int?> accountId = const Value.absent(),
            Value<int?> toAccountId = const Value.absent(),
            Value<String?> note = const Value.absent(),
            required String frequency,
            Value<int> interval = const Value.absent(),
            Value<int?> dayOfMonth = const Value.absent(),
            Value<int?> dayOfWeek = const Value.absent(),
            Value<int?> monthOfYear = const Value.absent(),
            required DateTime startDate,
            Value<DateTime?> endDate = const Value.absent(),
            Value<DateTime?> lastGeneratedDate = const Value.absent(),
            Value<bool> enabled = const Value.absent(),
            Value<String?> currencyCode = const Value.absent(),
            Value<String?> templateFieldValues = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
            Value<DateTime> updatedAt = const Value.absent(),
          }) =>
              RecurringTransactionsCompanion.insert(
            id: id,
            ledgerId: ledgerId,
            syncId: syncId,
            type: type,
            amount: amount,
            categoryId: categoryId,
            accountId: accountId,
            toAccountId: toAccountId,
            note: note,
            frequency: frequency,
            interval: interval,
            dayOfMonth: dayOfMonth,
            dayOfWeek: dayOfWeek,
            monthOfYear: monthOfYear,
            startDate: startDate,
            endDate: endDate,
            lastGeneratedDate: lastGeneratedDate,
            enabled: enabled,
            currencyCode: currencyCode,
            templateFieldValues: templateFieldValues,
            createdAt: createdAt,
            updatedAt: updatedAt,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable<$RecurringTransactionsTable,
                        RecurringTransaction>(table),
                    BaseReferences<_$PiggyDatabase, $RecurringTransactionsTable,
                        RecurringTransaction>(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$RecurringTransactionsTableProcessedTableManager
    = ProcessedTableManager<
        _$PiggyDatabase,
        $RecurringTransactionsTable,
        RecurringTransaction,
        $$RecurringTransactionsTableFilterComposer,
        $$RecurringTransactionsTableOrderingComposer,
        $$RecurringTransactionsTableAnnotationComposer,
        $$RecurringTransactionsTableCreateCompanionBuilder,
        $$RecurringTransactionsTableUpdateCompanionBuilder,
        (
          RecurringTransaction,
          BaseReferences<_$PiggyDatabase, $RecurringTransactionsTable,
              RecurringTransaction>
        ),
        RecurringTransaction,
        PrefetchHooks Function()>;
typedef $$ConversationsTableCreateCompanionBuilder = ConversationsCompanion
    Function({
  Value<int> id,
  Value<int?> ledgerId,
  Value<String> title,
  Value<DateTime> createdAt,
  Value<DateTime> updatedAt,
});
typedef $$ConversationsTableUpdateCompanionBuilder = ConversationsCompanion
    Function({
  Value<int> id,
  Value<int?> ledgerId,
  Value<String> title,
  Value<DateTime> createdAt,
  Value<DateTime> updatedAt,
});

class $$ConversationsTableFilterComposer
    extends Composer<_$PiggyDatabase, $ConversationsTable> {
  $$ConversationsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get ledgerId => $composableBuilder(
      column: $table.ledgerId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get title => $composableBuilder(
      column: $table.title, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnFilters(column));
}

class $$ConversationsTableOrderingComposer
    extends Composer<_$PiggyDatabase, $ConversationsTable> {
  $$ConversationsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get ledgerId => $composableBuilder(
      column: $table.ledgerId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get title => $composableBuilder(
      column: $table.title, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnOrderings(column));
}

class $$ConversationsTableAnnotationComposer
    extends Composer<_$PiggyDatabase, $ConversationsTable> {
  $$ConversationsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get ledgerId =>
      $composableBuilder(column: $table.ledgerId, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$ConversationsTableTableManager extends RootTableManager<
    _$PiggyDatabase,
    $ConversationsTable,
    Conversation,
    $$ConversationsTableFilterComposer,
    $$ConversationsTableOrderingComposer,
    $$ConversationsTableAnnotationComposer,
    $$ConversationsTableCreateCompanionBuilder,
    $$ConversationsTableUpdateCompanionBuilder,
    (
      Conversation,
      BaseReferences<_$PiggyDatabase, $ConversationsTable, Conversation>
    ),
    Conversation,
    PrefetchHooks Function()> {
  $$ConversationsTableTableManager(
      _$PiggyDatabase db, $ConversationsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ConversationsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ConversationsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ConversationsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<int?> ledgerId = const Value.absent(),
            Value<String> title = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
            Value<DateTime> updatedAt = const Value.absent(),
          }) =>
              ConversationsCompanion(
            id: id,
            ledgerId: ledgerId,
            title: title,
            createdAt: createdAt,
            updatedAt: updatedAt,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<int?> ledgerId = const Value.absent(),
            Value<String> title = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
            Value<DateTime> updatedAt = const Value.absent(),
          }) =>
              ConversationsCompanion.insert(
            id: id,
            ledgerId: ledgerId,
            title: title,
            createdAt: createdAt,
            updatedAt: updatedAt,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable<$ConversationsTable, Conversation>(table),
                    BaseReferences<_$PiggyDatabase, $ConversationsTable,
                        Conversation>(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$ConversationsTableProcessedTableManager = ProcessedTableManager<
    _$PiggyDatabase,
    $ConversationsTable,
    Conversation,
    $$ConversationsTableFilterComposer,
    $$ConversationsTableOrderingComposer,
    $$ConversationsTableAnnotationComposer,
    $$ConversationsTableCreateCompanionBuilder,
    $$ConversationsTableUpdateCompanionBuilder,
    (
      Conversation,
      BaseReferences<_$PiggyDatabase, $ConversationsTable, Conversation>
    ),
    Conversation,
    PrefetchHooks Function()>;
typedef $$MessagesTableCreateCompanionBuilder = MessagesCompanion Function({
  Value<int> id,
  required int conversationId,
  required String role,
  required String content,
  required String messageType,
  Value<String?> metadata,
  Value<int?> transactionId,
  Value<DateTime> createdAt,
});
typedef $$MessagesTableUpdateCompanionBuilder = MessagesCompanion Function({
  Value<int> id,
  Value<int> conversationId,
  Value<String> role,
  Value<String> content,
  Value<String> messageType,
  Value<String?> metadata,
  Value<int?> transactionId,
  Value<DateTime> createdAt,
});

class $$MessagesTableFilterComposer
    extends Composer<_$PiggyDatabase, $MessagesTable> {
  $$MessagesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get conversationId => $composableBuilder(
      column: $table.conversationId,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get role => $composableBuilder(
      column: $table.role, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get content => $composableBuilder(
      column: $table.content, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get messageType => $composableBuilder(
      column: $table.messageType, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get metadata => $composableBuilder(
      column: $table.metadata, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get transactionId => $composableBuilder(
      column: $table.transactionId, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));
}

class $$MessagesTableOrderingComposer
    extends Composer<_$PiggyDatabase, $MessagesTable> {
  $$MessagesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get conversationId => $composableBuilder(
      column: $table.conversationId,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get role => $composableBuilder(
      column: $table.role, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get content => $composableBuilder(
      column: $table.content, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get messageType => $composableBuilder(
      column: $table.messageType, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get metadata => $composableBuilder(
      column: $table.metadata, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get transactionId => $composableBuilder(
      column: $table.transactionId,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));
}

class $$MessagesTableAnnotationComposer
    extends Composer<_$PiggyDatabase, $MessagesTable> {
  $$MessagesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get conversationId => $composableBuilder(
      column: $table.conversationId, builder: (column) => column);

  GeneratedColumn<String> get role =>
      $composableBuilder(column: $table.role, builder: (column) => column);

  GeneratedColumn<String> get content =>
      $composableBuilder(column: $table.content, builder: (column) => column);

  GeneratedColumn<String> get messageType => $composableBuilder(
      column: $table.messageType, builder: (column) => column);

  GeneratedColumn<String> get metadata =>
      $composableBuilder(column: $table.metadata, builder: (column) => column);

  GeneratedColumn<int> get transactionId => $composableBuilder(
      column: $table.transactionId, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);
}

class $$MessagesTableTableManager extends RootTableManager<
    _$PiggyDatabase,
    $MessagesTable,
    Message,
    $$MessagesTableFilterComposer,
    $$MessagesTableOrderingComposer,
    $$MessagesTableAnnotationComposer,
    $$MessagesTableCreateCompanionBuilder,
    $$MessagesTableUpdateCompanionBuilder,
    (Message, BaseReferences<_$PiggyDatabase, $MessagesTable, Message>),
    Message,
    PrefetchHooks Function()> {
  $$MessagesTableTableManager(_$PiggyDatabase db, $MessagesTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$MessagesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$MessagesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$MessagesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<int> conversationId = const Value.absent(),
            Value<String> role = const Value.absent(),
            Value<String> content = const Value.absent(),
            Value<String> messageType = const Value.absent(),
            Value<String?> metadata = const Value.absent(),
            Value<int?> transactionId = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
          }) =>
              MessagesCompanion(
            id: id,
            conversationId: conversationId,
            role: role,
            content: content,
            messageType: messageType,
            metadata: metadata,
            transactionId: transactionId,
            createdAt: createdAt,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required int conversationId,
            required String role,
            required String content,
            required String messageType,
            Value<String?> metadata = const Value.absent(),
            Value<int?> transactionId = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
          }) =>
              MessagesCompanion.insert(
            id: id,
            conversationId: conversationId,
            role: role,
            content: content,
            messageType: messageType,
            metadata: metadata,
            transactionId: transactionId,
            createdAt: createdAt,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable<$MessagesTable, Message>(table),
                    BaseReferences<_$PiggyDatabase, $MessagesTable, Message>(
                        db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$MessagesTableProcessedTableManager = ProcessedTableManager<
    _$PiggyDatabase,
    $MessagesTable,
    Message,
    $$MessagesTableFilterComposer,
    $$MessagesTableOrderingComposer,
    $$MessagesTableAnnotationComposer,
    $$MessagesTableCreateCompanionBuilder,
    $$MessagesTableUpdateCompanionBuilder,
    (Message, BaseReferences<_$PiggyDatabase, $MessagesTable, Message>),
    Message,
    PrefetchHooks Function()>;
typedef $$TagsTableCreateCompanionBuilder = TagsCompanion Function({
  Value<int> id,
  required String name,
  Value<String?> color,
  Value<int> sortOrder,
  Value<DateTime> createdAt,
  Value<String?> syncId,
  Value<DateTime?> updatedAt,
});
typedef $$TagsTableUpdateCompanionBuilder = TagsCompanion Function({
  Value<int> id,
  Value<String> name,
  Value<String?> color,
  Value<int> sortOrder,
  Value<DateTime> createdAt,
  Value<String?> syncId,
  Value<DateTime?> updatedAt,
});

class $$TagsTableFilterComposer extends Composer<_$PiggyDatabase, $TagsTable> {
  $$TagsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get color => $composableBuilder(
      column: $table.color, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get sortOrder => $composableBuilder(
      column: $table.sortOrder, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get syncId => $composableBuilder(
      column: $table.syncId, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnFilters(column));
}

class $$TagsTableOrderingComposer
    extends Composer<_$PiggyDatabase, $TagsTable> {
  $$TagsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get color => $composableBuilder(
      column: $table.color, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get sortOrder => $composableBuilder(
      column: $table.sortOrder, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get syncId => $composableBuilder(
      column: $table.syncId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnOrderings(column));
}

class $$TagsTableAnnotationComposer
    extends Composer<_$PiggyDatabase, $TagsTable> {
  $$TagsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get color =>
      $composableBuilder(column: $table.color, builder: (column) => column);

  GeneratedColumn<int> get sortOrder =>
      $composableBuilder(column: $table.sortOrder, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<String> get syncId =>
      $composableBuilder(column: $table.syncId, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$TagsTableTableManager extends RootTableManager<
    _$PiggyDatabase,
    $TagsTable,
    Tag,
    $$TagsTableFilterComposer,
    $$TagsTableOrderingComposer,
    $$TagsTableAnnotationComposer,
    $$TagsTableCreateCompanionBuilder,
    $$TagsTableUpdateCompanionBuilder,
    (Tag, BaseReferences<_$PiggyDatabase, $TagsTable, Tag>),
    Tag,
    PrefetchHooks Function()> {
  $$TagsTableTableManager(_$PiggyDatabase db, $TagsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$TagsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$TagsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$TagsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> name = const Value.absent(),
            Value<String?> color = const Value.absent(),
            Value<int> sortOrder = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
            Value<String?> syncId = const Value.absent(),
            Value<DateTime?> updatedAt = const Value.absent(),
          }) =>
              TagsCompanion(
            id: id,
            name: name,
            color: color,
            sortOrder: sortOrder,
            createdAt: createdAt,
            syncId: syncId,
            updatedAt: updatedAt,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required String name,
            Value<String?> color = const Value.absent(),
            Value<int> sortOrder = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
            Value<String?> syncId = const Value.absent(),
            Value<DateTime?> updatedAt = const Value.absent(),
          }) =>
              TagsCompanion.insert(
            id: id,
            name: name,
            color: color,
            sortOrder: sortOrder,
            createdAt: createdAt,
            syncId: syncId,
            updatedAt: updatedAt,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable<$TagsTable, Tag>(table),
                    BaseReferences<_$PiggyDatabase, $TagsTable, Tag>(
                        db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$TagsTableProcessedTableManager = ProcessedTableManager<
    _$PiggyDatabase,
    $TagsTable,
    Tag,
    $$TagsTableFilterComposer,
    $$TagsTableOrderingComposer,
    $$TagsTableAnnotationComposer,
    $$TagsTableCreateCompanionBuilder,
    $$TagsTableUpdateCompanionBuilder,
    (Tag, BaseReferences<_$PiggyDatabase, $TagsTable, Tag>),
    Tag,
    PrefetchHooks Function()>;
typedef $$CustomFieldDefinitionsTableCreateCompanionBuilder
    = CustomFieldDefinitionsCompanion Function({
  Value<int> id,
  required int ledgerId,
  required String name,
  required String fieldType,
  Value<int> sortOrder,
  Value<DateTime> createdAt,
  Value<String?> syncId,
  Value<DateTime?> updatedAt,
});
typedef $$CustomFieldDefinitionsTableUpdateCompanionBuilder
    = CustomFieldDefinitionsCompanion Function({
  Value<int> id,
  Value<int> ledgerId,
  Value<String> name,
  Value<String> fieldType,
  Value<int> sortOrder,
  Value<DateTime> createdAt,
  Value<String?> syncId,
  Value<DateTime?> updatedAt,
});

class $$CustomFieldDefinitionsTableFilterComposer
    extends Composer<_$PiggyDatabase, $CustomFieldDefinitionsTable> {
  $$CustomFieldDefinitionsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get ledgerId => $composableBuilder(
      column: $table.ledgerId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get fieldType => $composableBuilder(
      column: $table.fieldType, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get sortOrder => $composableBuilder(
      column: $table.sortOrder, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get syncId => $composableBuilder(
      column: $table.syncId, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnFilters(column));
}

class $$CustomFieldDefinitionsTableOrderingComposer
    extends Composer<_$PiggyDatabase, $CustomFieldDefinitionsTable> {
  $$CustomFieldDefinitionsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get ledgerId => $composableBuilder(
      column: $table.ledgerId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get fieldType => $composableBuilder(
      column: $table.fieldType, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get sortOrder => $composableBuilder(
      column: $table.sortOrder, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get syncId => $composableBuilder(
      column: $table.syncId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnOrderings(column));
}

class $$CustomFieldDefinitionsTableAnnotationComposer
    extends Composer<_$PiggyDatabase, $CustomFieldDefinitionsTable> {
  $$CustomFieldDefinitionsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get ledgerId =>
      $composableBuilder(column: $table.ledgerId, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get fieldType =>
      $composableBuilder(column: $table.fieldType, builder: (column) => column);

  GeneratedColumn<int> get sortOrder =>
      $composableBuilder(column: $table.sortOrder, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<String> get syncId =>
      $composableBuilder(column: $table.syncId, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$CustomFieldDefinitionsTableTableManager extends RootTableManager<
    _$PiggyDatabase,
    $CustomFieldDefinitionsTable,
    CustomFieldDefinition,
    $$CustomFieldDefinitionsTableFilterComposer,
    $$CustomFieldDefinitionsTableOrderingComposer,
    $$CustomFieldDefinitionsTableAnnotationComposer,
    $$CustomFieldDefinitionsTableCreateCompanionBuilder,
    $$CustomFieldDefinitionsTableUpdateCompanionBuilder,
    (
      CustomFieldDefinition,
      BaseReferences<_$PiggyDatabase, $CustomFieldDefinitionsTable,
          CustomFieldDefinition>
    ),
    CustomFieldDefinition,
    PrefetchHooks Function()> {
  $$CustomFieldDefinitionsTableTableManager(
      _$PiggyDatabase db, $CustomFieldDefinitionsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CustomFieldDefinitionsTableFilterComposer(
                  $db: db, $table: table),
          createOrderingComposer: () =>
              $$CustomFieldDefinitionsTableOrderingComposer(
                  $db: db, $table: table),
          createComputedFieldComposer: () =>
              $$CustomFieldDefinitionsTableAnnotationComposer(
                  $db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<int> ledgerId = const Value.absent(),
            Value<String> name = const Value.absent(),
            Value<String> fieldType = const Value.absent(),
            Value<int> sortOrder = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
            Value<String?> syncId = const Value.absent(),
            Value<DateTime?> updatedAt = const Value.absent(),
          }) =>
              CustomFieldDefinitionsCompanion(
            id: id,
            ledgerId: ledgerId,
            name: name,
            fieldType: fieldType,
            sortOrder: sortOrder,
            createdAt: createdAt,
            syncId: syncId,
            updatedAt: updatedAt,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required int ledgerId,
            required String name,
            required String fieldType,
            Value<int> sortOrder = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
            Value<String?> syncId = const Value.absent(),
            Value<DateTime?> updatedAt = const Value.absent(),
          }) =>
              CustomFieldDefinitionsCompanion.insert(
            id: id,
            ledgerId: ledgerId,
            name: name,
            fieldType: fieldType,
            sortOrder: sortOrder,
            createdAt: createdAt,
            syncId: syncId,
            updatedAt: updatedAt,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable<$CustomFieldDefinitionsTable,
                        CustomFieldDefinition>(table),
                    BaseReferences<
                        _$PiggyDatabase,
                        $CustomFieldDefinitionsTable,
                        CustomFieldDefinition>(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$CustomFieldDefinitionsTableProcessedTableManager
    = ProcessedTableManager<
        _$PiggyDatabase,
        $CustomFieldDefinitionsTable,
        CustomFieldDefinition,
        $$CustomFieldDefinitionsTableFilterComposer,
        $$CustomFieldDefinitionsTableOrderingComposer,
        $$CustomFieldDefinitionsTableAnnotationComposer,
        $$CustomFieldDefinitionsTableCreateCompanionBuilder,
        $$CustomFieldDefinitionsTableUpdateCompanionBuilder,
        (
          CustomFieldDefinition,
          BaseReferences<_$PiggyDatabase, $CustomFieldDefinitionsTable,
              CustomFieldDefinition>
        ),
        CustomFieldDefinition,
        PrefetchHooks Function()>;
typedef $$TransactionTagsTableCreateCompanionBuilder = TransactionTagsCompanion
    Function({
  Value<int> id,
  required int transactionId,
  required int tagId,
});
typedef $$TransactionTagsTableUpdateCompanionBuilder = TransactionTagsCompanion
    Function({
  Value<int> id,
  Value<int> transactionId,
  Value<int> tagId,
});

class $$TransactionTagsTableFilterComposer
    extends Composer<_$PiggyDatabase, $TransactionTagsTable> {
  $$TransactionTagsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get transactionId => $composableBuilder(
      column: $table.transactionId, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get tagId => $composableBuilder(
      column: $table.tagId, builder: (column) => ColumnFilters(column));
}

class $$TransactionTagsTableOrderingComposer
    extends Composer<_$PiggyDatabase, $TransactionTagsTable> {
  $$TransactionTagsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get transactionId => $composableBuilder(
      column: $table.transactionId,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get tagId => $composableBuilder(
      column: $table.tagId, builder: (column) => ColumnOrderings(column));
}

class $$TransactionTagsTableAnnotationComposer
    extends Composer<_$PiggyDatabase, $TransactionTagsTable> {
  $$TransactionTagsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get transactionId => $composableBuilder(
      column: $table.transactionId, builder: (column) => column);

  GeneratedColumn<int> get tagId =>
      $composableBuilder(column: $table.tagId, builder: (column) => column);
}

class $$TransactionTagsTableTableManager extends RootTableManager<
    _$PiggyDatabase,
    $TransactionTagsTable,
    TransactionTag,
    $$TransactionTagsTableFilterComposer,
    $$TransactionTagsTableOrderingComposer,
    $$TransactionTagsTableAnnotationComposer,
    $$TransactionTagsTableCreateCompanionBuilder,
    $$TransactionTagsTableUpdateCompanionBuilder,
    (
      TransactionTag,
      BaseReferences<_$PiggyDatabase, $TransactionTagsTable, TransactionTag>
    ),
    TransactionTag,
    PrefetchHooks Function()> {
  $$TransactionTagsTableTableManager(
      _$PiggyDatabase db, $TransactionTagsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$TransactionTagsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$TransactionTagsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$TransactionTagsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<int> transactionId = const Value.absent(),
            Value<int> tagId = const Value.absent(),
          }) =>
              TransactionTagsCompanion(
            id: id,
            transactionId: transactionId,
            tagId: tagId,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required int transactionId,
            required int tagId,
          }) =>
              TransactionTagsCompanion.insert(
            id: id,
            transactionId: transactionId,
            tagId: tagId,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable<$TransactionTagsTable, TransactionTag>(table),
                    BaseReferences<_$PiggyDatabase, $TransactionTagsTable,
                        TransactionTag>(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$TransactionTagsTableProcessedTableManager = ProcessedTableManager<
    _$PiggyDatabase,
    $TransactionTagsTable,
    TransactionTag,
    $$TransactionTagsTableFilterComposer,
    $$TransactionTagsTableOrderingComposer,
    $$TransactionTagsTableAnnotationComposer,
    $$TransactionTagsTableCreateCompanionBuilder,
    $$TransactionTagsTableUpdateCompanionBuilder,
    (
      TransactionTag,
      BaseReferences<_$PiggyDatabase, $TransactionTagsTable, TransactionTag>
    ),
    TransactionTag,
    PrefetchHooks Function()>;
typedef $$BudgetsTableCreateCompanionBuilder = BudgetsCompanion Function({
  Value<int> id,
  Value<String?> syncId,
  required int ledgerId,
  Value<String> type,
  Value<int?> categoryId,
  required double amount,
  Value<String> period,
  Value<int> startDay,
  Value<bool> enabled,
  Value<DateTime> createdAt,
  Value<DateTime> updatedAt,
});
typedef $$BudgetsTableUpdateCompanionBuilder = BudgetsCompanion Function({
  Value<int> id,
  Value<String?> syncId,
  Value<int> ledgerId,
  Value<String> type,
  Value<int?> categoryId,
  Value<double> amount,
  Value<String> period,
  Value<int> startDay,
  Value<bool> enabled,
  Value<DateTime> createdAt,
  Value<DateTime> updatedAt,
});

class $$BudgetsTableFilterComposer
    extends Composer<_$PiggyDatabase, $BudgetsTable> {
  $$BudgetsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get syncId => $composableBuilder(
      column: $table.syncId, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get ledgerId => $composableBuilder(
      column: $table.ledgerId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get type => $composableBuilder(
      column: $table.type, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get categoryId => $composableBuilder(
      column: $table.categoryId, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get amount => $composableBuilder(
      column: $table.amount, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get period => $composableBuilder(
      column: $table.period, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get startDay => $composableBuilder(
      column: $table.startDay, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get enabled => $composableBuilder(
      column: $table.enabled, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnFilters(column));
}

class $$BudgetsTableOrderingComposer
    extends Composer<_$PiggyDatabase, $BudgetsTable> {
  $$BudgetsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get syncId => $composableBuilder(
      column: $table.syncId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get ledgerId => $composableBuilder(
      column: $table.ledgerId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get type => $composableBuilder(
      column: $table.type, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get categoryId => $composableBuilder(
      column: $table.categoryId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get amount => $composableBuilder(
      column: $table.amount, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get period => $composableBuilder(
      column: $table.period, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get startDay => $composableBuilder(
      column: $table.startDay, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get enabled => $composableBuilder(
      column: $table.enabled, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnOrderings(column));
}

class $$BudgetsTableAnnotationComposer
    extends Composer<_$PiggyDatabase, $BudgetsTable> {
  $$BudgetsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get syncId =>
      $composableBuilder(column: $table.syncId, builder: (column) => column);

  GeneratedColumn<int> get ledgerId =>
      $composableBuilder(column: $table.ledgerId, builder: (column) => column);

  GeneratedColumn<String> get type =>
      $composableBuilder(column: $table.type, builder: (column) => column);

  GeneratedColumn<int> get categoryId => $composableBuilder(
      column: $table.categoryId, builder: (column) => column);

  GeneratedColumn<double> get amount =>
      $composableBuilder(column: $table.amount, builder: (column) => column);

  GeneratedColumn<String> get period =>
      $composableBuilder(column: $table.period, builder: (column) => column);

  GeneratedColumn<int> get startDay =>
      $composableBuilder(column: $table.startDay, builder: (column) => column);

  GeneratedColumn<bool> get enabled =>
      $composableBuilder(column: $table.enabled, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$BudgetsTableTableManager extends RootTableManager<
    _$PiggyDatabase,
    $BudgetsTable,
    Budget,
    $$BudgetsTableFilterComposer,
    $$BudgetsTableOrderingComposer,
    $$BudgetsTableAnnotationComposer,
    $$BudgetsTableCreateCompanionBuilder,
    $$BudgetsTableUpdateCompanionBuilder,
    (Budget, BaseReferences<_$PiggyDatabase, $BudgetsTable, Budget>),
    Budget,
    PrefetchHooks Function()> {
  $$BudgetsTableTableManager(_$PiggyDatabase db, $BudgetsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$BudgetsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$BudgetsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$BudgetsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String?> syncId = const Value.absent(),
            Value<int> ledgerId = const Value.absent(),
            Value<String> type = const Value.absent(),
            Value<int?> categoryId = const Value.absent(),
            Value<double> amount = const Value.absent(),
            Value<String> period = const Value.absent(),
            Value<int> startDay = const Value.absent(),
            Value<bool> enabled = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
            Value<DateTime> updatedAt = const Value.absent(),
          }) =>
              BudgetsCompanion(
            id: id,
            syncId: syncId,
            ledgerId: ledgerId,
            type: type,
            categoryId: categoryId,
            amount: amount,
            period: period,
            startDay: startDay,
            enabled: enabled,
            createdAt: createdAt,
            updatedAt: updatedAt,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String?> syncId = const Value.absent(),
            required int ledgerId,
            Value<String> type = const Value.absent(),
            Value<int?> categoryId = const Value.absent(),
            required double amount,
            Value<String> period = const Value.absent(),
            Value<int> startDay = const Value.absent(),
            Value<bool> enabled = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
            Value<DateTime> updatedAt = const Value.absent(),
          }) =>
              BudgetsCompanion.insert(
            id: id,
            syncId: syncId,
            ledgerId: ledgerId,
            type: type,
            categoryId: categoryId,
            amount: amount,
            period: period,
            startDay: startDay,
            enabled: enabled,
            createdAt: createdAt,
            updatedAt: updatedAt,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable<$BudgetsTable, Budget>(table),
                    BaseReferences<_$PiggyDatabase, $BudgetsTable, Budget>(
                        db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$BudgetsTableProcessedTableManager = ProcessedTableManager<
    _$PiggyDatabase,
    $BudgetsTable,
    Budget,
    $$BudgetsTableFilterComposer,
    $$BudgetsTableOrderingComposer,
    $$BudgetsTableAnnotationComposer,
    $$BudgetsTableCreateCompanionBuilder,
    $$BudgetsTableUpdateCompanionBuilder,
    (Budget, BaseReferences<_$PiggyDatabase, $BudgetsTable, Budget>),
    Budget,
    PrefetchHooks Function()>;
typedef $$SavingsGoalsTableCreateCompanionBuilder = SavingsGoalsCompanion
    Function({
  Value<int> id,
  Value<String?> syncId,
  required int ledgerId,
  required String name,
  required double targetAmount,
  Value<String> currency,
  Value<int?> accountId,
  Value<double> savedAmount,
  Value<DateTime> startDate,
  Value<DateTime?> targetDate,
  Value<String?> note,
  Value<int> sortOrder,
  Value<DateTime> createdAt,
  Value<DateTime> updatedAt,
});
typedef $$SavingsGoalsTableUpdateCompanionBuilder = SavingsGoalsCompanion
    Function({
  Value<int> id,
  Value<String?> syncId,
  Value<int> ledgerId,
  Value<String> name,
  Value<double> targetAmount,
  Value<String> currency,
  Value<int?> accountId,
  Value<double> savedAmount,
  Value<DateTime> startDate,
  Value<DateTime?> targetDate,
  Value<String?> note,
  Value<int> sortOrder,
  Value<DateTime> createdAt,
  Value<DateTime> updatedAt,
});

class $$SavingsGoalsTableFilterComposer
    extends Composer<_$PiggyDatabase, $SavingsGoalsTable> {
  $$SavingsGoalsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get syncId => $composableBuilder(
      column: $table.syncId, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get ledgerId => $composableBuilder(
      column: $table.ledgerId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get targetAmount => $composableBuilder(
      column: $table.targetAmount, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get currency => $composableBuilder(
      column: $table.currency, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get accountId => $composableBuilder(
      column: $table.accountId, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get savedAmount => $composableBuilder(
      column: $table.savedAmount, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get startDate => $composableBuilder(
      column: $table.startDate, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get targetDate => $composableBuilder(
      column: $table.targetDate, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get note => $composableBuilder(
      column: $table.note, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get sortOrder => $composableBuilder(
      column: $table.sortOrder, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnFilters(column));
}

class $$SavingsGoalsTableOrderingComposer
    extends Composer<_$PiggyDatabase, $SavingsGoalsTable> {
  $$SavingsGoalsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get syncId => $composableBuilder(
      column: $table.syncId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get ledgerId => $composableBuilder(
      column: $table.ledgerId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get targetAmount => $composableBuilder(
      column: $table.targetAmount,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get currency => $composableBuilder(
      column: $table.currency, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get accountId => $composableBuilder(
      column: $table.accountId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get savedAmount => $composableBuilder(
      column: $table.savedAmount, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get startDate => $composableBuilder(
      column: $table.startDate, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get targetDate => $composableBuilder(
      column: $table.targetDate, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get note => $composableBuilder(
      column: $table.note, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get sortOrder => $composableBuilder(
      column: $table.sortOrder, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnOrderings(column));
}

class $$SavingsGoalsTableAnnotationComposer
    extends Composer<_$PiggyDatabase, $SavingsGoalsTable> {
  $$SavingsGoalsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get syncId =>
      $composableBuilder(column: $table.syncId, builder: (column) => column);

  GeneratedColumn<int> get ledgerId =>
      $composableBuilder(column: $table.ledgerId, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<double> get targetAmount => $composableBuilder(
      column: $table.targetAmount, builder: (column) => column);

  GeneratedColumn<String> get currency =>
      $composableBuilder(column: $table.currency, builder: (column) => column);

  GeneratedColumn<int> get accountId =>
      $composableBuilder(column: $table.accountId, builder: (column) => column);

  GeneratedColumn<double> get savedAmount => $composableBuilder(
      column: $table.savedAmount, builder: (column) => column);

  GeneratedColumn<DateTime> get startDate =>
      $composableBuilder(column: $table.startDate, builder: (column) => column);

  GeneratedColumn<DateTime> get targetDate => $composableBuilder(
      column: $table.targetDate, builder: (column) => column);

  GeneratedColumn<String> get note =>
      $composableBuilder(column: $table.note, builder: (column) => column);

  GeneratedColumn<int> get sortOrder =>
      $composableBuilder(column: $table.sortOrder, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$SavingsGoalsTableTableManager extends RootTableManager<
    _$PiggyDatabase,
    $SavingsGoalsTable,
    SavingsGoal,
    $$SavingsGoalsTableFilterComposer,
    $$SavingsGoalsTableOrderingComposer,
    $$SavingsGoalsTableAnnotationComposer,
    $$SavingsGoalsTableCreateCompanionBuilder,
    $$SavingsGoalsTableUpdateCompanionBuilder,
    (
      SavingsGoal,
      BaseReferences<_$PiggyDatabase, $SavingsGoalsTable, SavingsGoal>
    ),
    SavingsGoal,
    PrefetchHooks Function()> {
  $$SavingsGoalsTableTableManager(_$PiggyDatabase db, $SavingsGoalsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SavingsGoalsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SavingsGoalsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SavingsGoalsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String?> syncId = const Value.absent(),
            Value<int> ledgerId = const Value.absent(),
            Value<String> name = const Value.absent(),
            Value<double> targetAmount = const Value.absent(),
            Value<String> currency = const Value.absent(),
            Value<int?> accountId = const Value.absent(),
            Value<double> savedAmount = const Value.absent(),
            Value<DateTime> startDate = const Value.absent(),
            Value<DateTime?> targetDate = const Value.absent(),
            Value<String?> note = const Value.absent(),
            Value<int> sortOrder = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
            Value<DateTime> updatedAt = const Value.absent(),
          }) =>
              SavingsGoalsCompanion(
            id: id,
            syncId: syncId,
            ledgerId: ledgerId,
            name: name,
            targetAmount: targetAmount,
            currency: currency,
            accountId: accountId,
            savedAmount: savedAmount,
            startDate: startDate,
            targetDate: targetDate,
            note: note,
            sortOrder: sortOrder,
            createdAt: createdAt,
            updatedAt: updatedAt,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String?> syncId = const Value.absent(),
            required int ledgerId,
            required String name,
            required double targetAmount,
            Value<String> currency = const Value.absent(),
            Value<int?> accountId = const Value.absent(),
            Value<double> savedAmount = const Value.absent(),
            Value<DateTime> startDate = const Value.absent(),
            Value<DateTime?> targetDate = const Value.absent(),
            Value<String?> note = const Value.absent(),
            Value<int> sortOrder = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
            Value<DateTime> updatedAt = const Value.absent(),
          }) =>
              SavingsGoalsCompanion.insert(
            id: id,
            syncId: syncId,
            ledgerId: ledgerId,
            name: name,
            targetAmount: targetAmount,
            currency: currency,
            accountId: accountId,
            savedAmount: savedAmount,
            startDate: startDate,
            targetDate: targetDate,
            note: note,
            sortOrder: sortOrder,
            createdAt: createdAt,
            updatedAt: updatedAt,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable<$SavingsGoalsTable, SavingsGoal>(table),
                    BaseReferences<_$PiggyDatabase, $SavingsGoalsTable,
                        SavingsGoal>(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$SavingsGoalsTableProcessedTableManager = ProcessedTableManager<
    _$PiggyDatabase,
    $SavingsGoalsTable,
    SavingsGoal,
    $$SavingsGoalsTableFilterComposer,
    $$SavingsGoalsTableOrderingComposer,
    $$SavingsGoalsTableAnnotationComposer,
    $$SavingsGoalsTableCreateCompanionBuilder,
    $$SavingsGoalsTableUpdateCompanionBuilder,
    (
      SavingsGoal,
      BaseReferences<_$PiggyDatabase, $SavingsGoalsTable, SavingsGoal>
    ),
    SavingsGoal,
    PrefetchHooks Function()>;
typedef $$TransactionAttachmentsTableCreateCompanionBuilder
    = TransactionAttachmentsCompanion Function({
  Value<int> id,
  required int transactionId,
  required String fileName,
  Value<String?> originalName,
  Value<int?> fileSize,
  Value<int?> width,
  Value<int?> height,
  Value<int> sortOrder,
  Value<String?> cloudFileId,
  Value<String?> cloudSha256,
  Value<String?> localSha256,
  Value<DateTime> createdAt,
});
typedef $$TransactionAttachmentsTableUpdateCompanionBuilder
    = TransactionAttachmentsCompanion Function({
  Value<int> id,
  Value<int> transactionId,
  Value<String> fileName,
  Value<String?> originalName,
  Value<int?> fileSize,
  Value<int?> width,
  Value<int?> height,
  Value<int> sortOrder,
  Value<String?> cloudFileId,
  Value<String?> cloudSha256,
  Value<String?> localSha256,
  Value<DateTime> createdAt,
});

class $$TransactionAttachmentsTableFilterComposer
    extends Composer<_$PiggyDatabase, $TransactionAttachmentsTable> {
  $$TransactionAttachmentsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get transactionId => $composableBuilder(
      column: $table.transactionId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get fileName => $composableBuilder(
      column: $table.fileName, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get originalName => $composableBuilder(
      column: $table.originalName, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get fileSize => $composableBuilder(
      column: $table.fileSize, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get width => $composableBuilder(
      column: $table.width, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get height => $composableBuilder(
      column: $table.height, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get sortOrder => $composableBuilder(
      column: $table.sortOrder, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get cloudFileId => $composableBuilder(
      column: $table.cloudFileId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get cloudSha256 => $composableBuilder(
      column: $table.cloudSha256, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get localSha256 => $composableBuilder(
      column: $table.localSha256, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));
}

class $$TransactionAttachmentsTableOrderingComposer
    extends Composer<_$PiggyDatabase, $TransactionAttachmentsTable> {
  $$TransactionAttachmentsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get transactionId => $composableBuilder(
      column: $table.transactionId,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get fileName => $composableBuilder(
      column: $table.fileName, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get originalName => $composableBuilder(
      column: $table.originalName,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get fileSize => $composableBuilder(
      column: $table.fileSize, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get width => $composableBuilder(
      column: $table.width, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get height => $composableBuilder(
      column: $table.height, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get sortOrder => $composableBuilder(
      column: $table.sortOrder, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get cloudFileId => $composableBuilder(
      column: $table.cloudFileId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get cloudSha256 => $composableBuilder(
      column: $table.cloudSha256, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get localSha256 => $composableBuilder(
      column: $table.localSha256, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));
}

class $$TransactionAttachmentsTableAnnotationComposer
    extends Composer<_$PiggyDatabase, $TransactionAttachmentsTable> {
  $$TransactionAttachmentsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get transactionId => $composableBuilder(
      column: $table.transactionId, builder: (column) => column);

  GeneratedColumn<String> get fileName =>
      $composableBuilder(column: $table.fileName, builder: (column) => column);

  GeneratedColumn<String> get originalName => $composableBuilder(
      column: $table.originalName, builder: (column) => column);

  GeneratedColumn<int> get fileSize =>
      $composableBuilder(column: $table.fileSize, builder: (column) => column);

  GeneratedColumn<int> get width =>
      $composableBuilder(column: $table.width, builder: (column) => column);

  GeneratedColumn<int> get height =>
      $composableBuilder(column: $table.height, builder: (column) => column);

  GeneratedColumn<int> get sortOrder =>
      $composableBuilder(column: $table.sortOrder, builder: (column) => column);

  GeneratedColumn<String> get cloudFileId => $composableBuilder(
      column: $table.cloudFileId, builder: (column) => column);

  GeneratedColumn<String> get cloudSha256 => $composableBuilder(
      column: $table.cloudSha256, builder: (column) => column);

  GeneratedColumn<String> get localSha256 => $composableBuilder(
      column: $table.localSha256, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);
}

class $$TransactionAttachmentsTableTableManager extends RootTableManager<
    _$PiggyDatabase,
    $TransactionAttachmentsTable,
    TransactionAttachment,
    $$TransactionAttachmentsTableFilterComposer,
    $$TransactionAttachmentsTableOrderingComposer,
    $$TransactionAttachmentsTableAnnotationComposer,
    $$TransactionAttachmentsTableCreateCompanionBuilder,
    $$TransactionAttachmentsTableUpdateCompanionBuilder,
    (
      TransactionAttachment,
      BaseReferences<_$PiggyDatabase, $TransactionAttachmentsTable,
          TransactionAttachment>
    ),
    TransactionAttachment,
    PrefetchHooks Function()> {
  $$TransactionAttachmentsTableTableManager(
      _$PiggyDatabase db, $TransactionAttachmentsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$TransactionAttachmentsTableFilterComposer(
                  $db: db, $table: table),
          createOrderingComposer: () =>
              $$TransactionAttachmentsTableOrderingComposer(
                  $db: db, $table: table),
          createComputedFieldComposer: () =>
              $$TransactionAttachmentsTableAnnotationComposer(
                  $db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<int> transactionId = const Value.absent(),
            Value<String> fileName = const Value.absent(),
            Value<String?> originalName = const Value.absent(),
            Value<int?> fileSize = const Value.absent(),
            Value<int?> width = const Value.absent(),
            Value<int?> height = const Value.absent(),
            Value<int> sortOrder = const Value.absent(),
            Value<String?> cloudFileId = const Value.absent(),
            Value<String?> cloudSha256 = const Value.absent(),
            Value<String?> localSha256 = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
          }) =>
              TransactionAttachmentsCompanion(
            id: id,
            transactionId: transactionId,
            fileName: fileName,
            originalName: originalName,
            fileSize: fileSize,
            width: width,
            height: height,
            sortOrder: sortOrder,
            cloudFileId: cloudFileId,
            cloudSha256: cloudSha256,
            localSha256: localSha256,
            createdAt: createdAt,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required int transactionId,
            required String fileName,
            Value<String?> originalName = const Value.absent(),
            Value<int?> fileSize = const Value.absent(),
            Value<int?> width = const Value.absent(),
            Value<int?> height = const Value.absent(),
            Value<int> sortOrder = const Value.absent(),
            Value<String?> cloudFileId = const Value.absent(),
            Value<String?> cloudSha256 = const Value.absent(),
            Value<String?> localSha256 = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
          }) =>
              TransactionAttachmentsCompanion.insert(
            id: id,
            transactionId: transactionId,
            fileName: fileName,
            originalName: originalName,
            fileSize: fileSize,
            width: width,
            height: height,
            sortOrder: sortOrder,
            cloudFileId: cloudFileId,
            cloudSha256: cloudSha256,
            localSha256: localSha256,
            createdAt: createdAt,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable<$TransactionAttachmentsTable,
                        TransactionAttachment>(table),
                    BaseReferences<
                        _$PiggyDatabase,
                        $TransactionAttachmentsTable,
                        TransactionAttachment>(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$TransactionAttachmentsTableProcessedTableManager
    = ProcessedTableManager<
        _$PiggyDatabase,
        $TransactionAttachmentsTable,
        TransactionAttachment,
        $$TransactionAttachmentsTableFilterComposer,
        $$TransactionAttachmentsTableOrderingComposer,
        $$TransactionAttachmentsTableAnnotationComposer,
        $$TransactionAttachmentsTableCreateCompanionBuilder,
        $$TransactionAttachmentsTableUpdateCompanionBuilder,
        (
          TransactionAttachment,
          BaseReferences<_$PiggyDatabase, $TransactionAttachmentsTable,
              TransactionAttachment>
        ),
        TransactionAttachment,
        PrefetchHooks Function()>;
typedef $$LocalChangesTableCreateCompanionBuilder = LocalChangesCompanion
    Function({
  Value<int> id,
  required String entityType,
  required int entityId,
  required String entitySyncId,
  required int ledgerId,
  required String action,
  Value<String?> payloadJson,
  Value<DateTime> createdAt,
  Value<DateTime?> pushedAt,
});
typedef $$LocalChangesTableUpdateCompanionBuilder = LocalChangesCompanion
    Function({
  Value<int> id,
  Value<String> entityType,
  Value<int> entityId,
  Value<String> entitySyncId,
  Value<int> ledgerId,
  Value<String> action,
  Value<String?> payloadJson,
  Value<DateTime> createdAt,
  Value<DateTime?> pushedAt,
});

class $$LocalChangesTableFilterComposer
    extends Composer<_$PiggyDatabase, $LocalChangesTable> {
  $$LocalChangesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get entityType => $composableBuilder(
      column: $table.entityType, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get entityId => $composableBuilder(
      column: $table.entityId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get entitySyncId => $composableBuilder(
      column: $table.entitySyncId, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get ledgerId => $composableBuilder(
      column: $table.ledgerId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get action => $composableBuilder(
      column: $table.action, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get payloadJson => $composableBuilder(
      column: $table.payloadJson, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get pushedAt => $composableBuilder(
      column: $table.pushedAt, builder: (column) => ColumnFilters(column));
}

class $$LocalChangesTableOrderingComposer
    extends Composer<_$PiggyDatabase, $LocalChangesTable> {
  $$LocalChangesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get entityType => $composableBuilder(
      column: $table.entityType, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get entityId => $composableBuilder(
      column: $table.entityId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get entitySyncId => $composableBuilder(
      column: $table.entitySyncId,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get ledgerId => $composableBuilder(
      column: $table.ledgerId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get action => $composableBuilder(
      column: $table.action, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get payloadJson => $composableBuilder(
      column: $table.payloadJson, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get pushedAt => $composableBuilder(
      column: $table.pushedAt, builder: (column) => ColumnOrderings(column));
}

class $$LocalChangesTableAnnotationComposer
    extends Composer<_$PiggyDatabase, $LocalChangesTable> {
  $$LocalChangesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get entityType => $composableBuilder(
      column: $table.entityType, builder: (column) => column);

  GeneratedColumn<int> get entityId =>
      $composableBuilder(column: $table.entityId, builder: (column) => column);

  GeneratedColumn<String> get entitySyncId => $composableBuilder(
      column: $table.entitySyncId, builder: (column) => column);

  GeneratedColumn<int> get ledgerId =>
      $composableBuilder(column: $table.ledgerId, builder: (column) => column);

  GeneratedColumn<String> get action =>
      $composableBuilder(column: $table.action, builder: (column) => column);

  GeneratedColumn<String> get payloadJson => $composableBuilder(
      column: $table.payloadJson, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get pushedAt =>
      $composableBuilder(column: $table.pushedAt, builder: (column) => column);
}

class $$LocalChangesTableTableManager extends RootTableManager<
    _$PiggyDatabase,
    $LocalChangesTable,
    LocalChange,
    $$LocalChangesTableFilterComposer,
    $$LocalChangesTableOrderingComposer,
    $$LocalChangesTableAnnotationComposer,
    $$LocalChangesTableCreateCompanionBuilder,
    $$LocalChangesTableUpdateCompanionBuilder,
    (
      LocalChange,
      BaseReferences<_$PiggyDatabase, $LocalChangesTable, LocalChange>
    ),
    LocalChange,
    PrefetchHooks Function()> {
  $$LocalChangesTableTableManager(_$PiggyDatabase db, $LocalChangesTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalChangesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LocalChangesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LocalChangesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> entityType = const Value.absent(),
            Value<int> entityId = const Value.absent(),
            Value<String> entitySyncId = const Value.absent(),
            Value<int> ledgerId = const Value.absent(),
            Value<String> action = const Value.absent(),
            Value<String?> payloadJson = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
            Value<DateTime?> pushedAt = const Value.absent(),
          }) =>
              LocalChangesCompanion(
            id: id,
            entityType: entityType,
            entityId: entityId,
            entitySyncId: entitySyncId,
            ledgerId: ledgerId,
            action: action,
            payloadJson: payloadJson,
            createdAt: createdAt,
            pushedAt: pushedAt,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required String entityType,
            required int entityId,
            required String entitySyncId,
            required int ledgerId,
            required String action,
            Value<String?> payloadJson = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
            Value<DateTime?> pushedAt = const Value.absent(),
          }) =>
              LocalChangesCompanion.insert(
            id: id,
            entityType: entityType,
            entityId: entityId,
            entitySyncId: entitySyncId,
            ledgerId: ledgerId,
            action: action,
            payloadJson: payloadJson,
            createdAt: createdAt,
            pushedAt: pushedAt,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable<$LocalChangesTable, LocalChange>(table),
                    BaseReferences<_$PiggyDatabase, $LocalChangesTable,
                        LocalChange>(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$LocalChangesTableProcessedTableManager = ProcessedTableManager<
    _$PiggyDatabase,
    $LocalChangesTable,
    LocalChange,
    $$LocalChangesTableFilterComposer,
    $$LocalChangesTableOrderingComposer,
    $$LocalChangesTableAnnotationComposer,
    $$LocalChangesTableCreateCompanionBuilder,
    $$LocalChangesTableUpdateCompanionBuilder,
    (
      LocalChange,
      BaseReferences<_$PiggyDatabase, $LocalChangesTable, LocalChange>
    ),
    LocalChange,
    PrefetchHooks Function()>;
typedef $$SyncPullErrorsTableCreateCompanionBuilder = SyncPullErrorsCompanion
    Function({
  Value<int> id,
  required int changeId,
  Value<String?> ledgerExternalId,
  required String entityType,
  required String entitySyncId,
  required String action,
  required String rawChangeJson,
  Value<String?> errorClass,
  Value<String?> errorMessage,
  Value<String?> stackTrace,
  required DateTime firstSeenAt,
  required DateTime lastAttemptAt,
  Value<int> attemptCount,
  Value<String?> userAction,
  Value<DateTime?> resolvedAt,
});
typedef $$SyncPullErrorsTableUpdateCompanionBuilder = SyncPullErrorsCompanion
    Function({
  Value<int> id,
  Value<int> changeId,
  Value<String?> ledgerExternalId,
  Value<String> entityType,
  Value<String> entitySyncId,
  Value<String> action,
  Value<String> rawChangeJson,
  Value<String?> errorClass,
  Value<String?> errorMessage,
  Value<String?> stackTrace,
  Value<DateTime> firstSeenAt,
  Value<DateTime> lastAttemptAt,
  Value<int> attemptCount,
  Value<String?> userAction,
  Value<DateTime?> resolvedAt,
});

class $$SyncPullErrorsTableFilterComposer
    extends Composer<_$PiggyDatabase, $SyncPullErrorsTable> {
  $$SyncPullErrorsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get changeId => $composableBuilder(
      column: $table.changeId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get ledgerExternalId => $composableBuilder(
      column: $table.ledgerExternalId,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get entityType => $composableBuilder(
      column: $table.entityType, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get entitySyncId => $composableBuilder(
      column: $table.entitySyncId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get action => $composableBuilder(
      column: $table.action, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get rawChangeJson => $composableBuilder(
      column: $table.rawChangeJson, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get errorClass => $composableBuilder(
      column: $table.errorClass, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get errorMessage => $composableBuilder(
      column: $table.errorMessage, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get stackTrace => $composableBuilder(
      column: $table.stackTrace, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get firstSeenAt => $composableBuilder(
      column: $table.firstSeenAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get lastAttemptAt => $composableBuilder(
      column: $table.lastAttemptAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get attemptCount => $composableBuilder(
      column: $table.attemptCount, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get userAction => $composableBuilder(
      column: $table.userAction, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get resolvedAt => $composableBuilder(
      column: $table.resolvedAt, builder: (column) => ColumnFilters(column));
}

class $$SyncPullErrorsTableOrderingComposer
    extends Composer<_$PiggyDatabase, $SyncPullErrorsTable> {
  $$SyncPullErrorsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get changeId => $composableBuilder(
      column: $table.changeId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get ledgerExternalId => $composableBuilder(
      column: $table.ledgerExternalId,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get entityType => $composableBuilder(
      column: $table.entityType, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get entitySyncId => $composableBuilder(
      column: $table.entitySyncId,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get action => $composableBuilder(
      column: $table.action, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get rawChangeJson => $composableBuilder(
      column: $table.rawChangeJson,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get errorClass => $composableBuilder(
      column: $table.errorClass, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get errorMessage => $composableBuilder(
      column: $table.errorMessage,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get stackTrace => $composableBuilder(
      column: $table.stackTrace, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get firstSeenAt => $composableBuilder(
      column: $table.firstSeenAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get lastAttemptAt => $composableBuilder(
      column: $table.lastAttemptAt,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get attemptCount => $composableBuilder(
      column: $table.attemptCount,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get userAction => $composableBuilder(
      column: $table.userAction, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get resolvedAt => $composableBuilder(
      column: $table.resolvedAt, builder: (column) => ColumnOrderings(column));
}

class $$SyncPullErrorsTableAnnotationComposer
    extends Composer<_$PiggyDatabase, $SyncPullErrorsTable> {
  $$SyncPullErrorsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get changeId =>
      $composableBuilder(column: $table.changeId, builder: (column) => column);

  GeneratedColumn<String> get ledgerExternalId => $composableBuilder(
      column: $table.ledgerExternalId, builder: (column) => column);

  GeneratedColumn<String> get entityType => $composableBuilder(
      column: $table.entityType, builder: (column) => column);

  GeneratedColumn<String> get entitySyncId => $composableBuilder(
      column: $table.entitySyncId, builder: (column) => column);

  GeneratedColumn<String> get action =>
      $composableBuilder(column: $table.action, builder: (column) => column);

  GeneratedColumn<String> get rawChangeJson => $composableBuilder(
      column: $table.rawChangeJson, builder: (column) => column);

  GeneratedColumn<String> get errorClass => $composableBuilder(
      column: $table.errorClass, builder: (column) => column);

  GeneratedColumn<String> get errorMessage => $composableBuilder(
      column: $table.errorMessage, builder: (column) => column);

  GeneratedColumn<String> get stackTrace => $composableBuilder(
      column: $table.stackTrace, builder: (column) => column);

  GeneratedColumn<DateTime> get firstSeenAt => $composableBuilder(
      column: $table.firstSeenAt, builder: (column) => column);

  GeneratedColumn<DateTime> get lastAttemptAt => $composableBuilder(
      column: $table.lastAttemptAt, builder: (column) => column);

  GeneratedColumn<int> get attemptCount => $composableBuilder(
      column: $table.attemptCount, builder: (column) => column);

  GeneratedColumn<String> get userAction => $composableBuilder(
      column: $table.userAction, builder: (column) => column);

  GeneratedColumn<DateTime> get resolvedAt => $composableBuilder(
      column: $table.resolvedAt, builder: (column) => column);
}

class $$SyncPullErrorsTableTableManager extends RootTableManager<
    _$PiggyDatabase,
    $SyncPullErrorsTable,
    SyncPullError,
    $$SyncPullErrorsTableFilterComposer,
    $$SyncPullErrorsTableOrderingComposer,
    $$SyncPullErrorsTableAnnotationComposer,
    $$SyncPullErrorsTableCreateCompanionBuilder,
    $$SyncPullErrorsTableUpdateCompanionBuilder,
    (
      SyncPullError,
      BaseReferences<_$PiggyDatabase, $SyncPullErrorsTable, SyncPullError>
    ),
    SyncPullError,
    PrefetchHooks Function()> {
  $$SyncPullErrorsTableTableManager(
      _$PiggyDatabase db, $SyncPullErrorsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SyncPullErrorsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SyncPullErrorsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SyncPullErrorsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<int> changeId = const Value.absent(),
            Value<String?> ledgerExternalId = const Value.absent(),
            Value<String> entityType = const Value.absent(),
            Value<String> entitySyncId = const Value.absent(),
            Value<String> action = const Value.absent(),
            Value<String> rawChangeJson = const Value.absent(),
            Value<String?> errorClass = const Value.absent(),
            Value<String?> errorMessage = const Value.absent(),
            Value<String?> stackTrace = const Value.absent(),
            Value<DateTime> firstSeenAt = const Value.absent(),
            Value<DateTime> lastAttemptAt = const Value.absent(),
            Value<int> attemptCount = const Value.absent(),
            Value<String?> userAction = const Value.absent(),
            Value<DateTime?> resolvedAt = const Value.absent(),
          }) =>
              SyncPullErrorsCompanion(
            id: id,
            changeId: changeId,
            ledgerExternalId: ledgerExternalId,
            entityType: entityType,
            entitySyncId: entitySyncId,
            action: action,
            rawChangeJson: rawChangeJson,
            errorClass: errorClass,
            errorMessage: errorMessage,
            stackTrace: stackTrace,
            firstSeenAt: firstSeenAt,
            lastAttemptAt: lastAttemptAt,
            attemptCount: attemptCount,
            userAction: userAction,
            resolvedAt: resolvedAt,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required int changeId,
            Value<String?> ledgerExternalId = const Value.absent(),
            required String entityType,
            required String entitySyncId,
            required String action,
            required String rawChangeJson,
            Value<String?> errorClass = const Value.absent(),
            Value<String?> errorMessage = const Value.absent(),
            Value<String?> stackTrace = const Value.absent(),
            required DateTime firstSeenAt,
            required DateTime lastAttemptAt,
            Value<int> attemptCount = const Value.absent(),
            Value<String?> userAction = const Value.absent(),
            Value<DateTime?> resolvedAt = const Value.absent(),
          }) =>
              SyncPullErrorsCompanion.insert(
            id: id,
            changeId: changeId,
            ledgerExternalId: ledgerExternalId,
            entityType: entityType,
            entitySyncId: entitySyncId,
            action: action,
            rawChangeJson: rawChangeJson,
            errorClass: errorClass,
            errorMessage: errorMessage,
            stackTrace: stackTrace,
            firstSeenAt: firstSeenAt,
            lastAttemptAt: lastAttemptAt,
            attemptCount: attemptCount,
            userAction: userAction,
            resolvedAt: resolvedAt,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable<$SyncPullErrorsTable, SyncPullError>(table),
                    BaseReferences<_$PiggyDatabase, $SyncPullErrorsTable,
                        SyncPullError>(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$SyncPullErrorsTableProcessedTableManager = ProcessedTableManager<
    _$PiggyDatabase,
    $SyncPullErrorsTable,
    SyncPullError,
    $$SyncPullErrorsTableFilterComposer,
    $$SyncPullErrorsTableOrderingComposer,
    $$SyncPullErrorsTableAnnotationComposer,
    $$SyncPullErrorsTableCreateCompanionBuilder,
    $$SyncPullErrorsTableUpdateCompanionBuilder,
    (
      SyncPullError,
      BaseReferences<_$PiggyDatabase, $SyncPullErrorsTable, SyncPullError>
    ),
    SyncPullError,
    PrefetchHooks Function()>;
typedef $$ExchangeRatesTableCreateCompanionBuilder = ExchangeRatesCompanion
    Function({
  required String baseCurrency,
  required String quoteCurrency,
  required String rateDate,
  required String rate,
  required String source,
  required DateTime fetchedAt,
  Value<int> rowid,
});
typedef $$ExchangeRatesTableUpdateCompanionBuilder = ExchangeRatesCompanion
    Function({
  Value<String> baseCurrency,
  Value<String> quoteCurrency,
  Value<String> rateDate,
  Value<String> rate,
  Value<String> source,
  Value<DateTime> fetchedAt,
  Value<int> rowid,
});

class $$ExchangeRatesTableFilterComposer
    extends Composer<_$PiggyDatabase, $ExchangeRatesTable> {
  $$ExchangeRatesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get baseCurrency => $composableBuilder(
      column: $table.baseCurrency, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get quoteCurrency => $composableBuilder(
      column: $table.quoteCurrency, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get rateDate => $composableBuilder(
      column: $table.rateDate, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get rate => $composableBuilder(
      column: $table.rate, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get source => $composableBuilder(
      column: $table.source, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get fetchedAt => $composableBuilder(
      column: $table.fetchedAt, builder: (column) => ColumnFilters(column));
}

class $$ExchangeRatesTableOrderingComposer
    extends Composer<_$PiggyDatabase, $ExchangeRatesTable> {
  $$ExchangeRatesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get baseCurrency => $composableBuilder(
      column: $table.baseCurrency,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get quoteCurrency => $composableBuilder(
      column: $table.quoteCurrency,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get rateDate => $composableBuilder(
      column: $table.rateDate, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get rate => $composableBuilder(
      column: $table.rate, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get source => $composableBuilder(
      column: $table.source, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get fetchedAt => $composableBuilder(
      column: $table.fetchedAt, builder: (column) => ColumnOrderings(column));
}

class $$ExchangeRatesTableAnnotationComposer
    extends Composer<_$PiggyDatabase, $ExchangeRatesTable> {
  $$ExchangeRatesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get baseCurrency => $composableBuilder(
      column: $table.baseCurrency, builder: (column) => column);

  GeneratedColumn<String> get quoteCurrency => $composableBuilder(
      column: $table.quoteCurrency, builder: (column) => column);

  GeneratedColumn<String> get rateDate =>
      $composableBuilder(column: $table.rateDate, builder: (column) => column);

  GeneratedColumn<String> get rate =>
      $composableBuilder(column: $table.rate, builder: (column) => column);

  GeneratedColumn<String> get source =>
      $composableBuilder(column: $table.source, builder: (column) => column);

  GeneratedColumn<DateTime> get fetchedAt =>
      $composableBuilder(column: $table.fetchedAt, builder: (column) => column);
}

class $$ExchangeRatesTableTableManager extends RootTableManager<
    _$PiggyDatabase,
    $ExchangeRatesTable,
    ExchangeRate,
    $$ExchangeRatesTableFilterComposer,
    $$ExchangeRatesTableOrderingComposer,
    $$ExchangeRatesTableAnnotationComposer,
    $$ExchangeRatesTableCreateCompanionBuilder,
    $$ExchangeRatesTableUpdateCompanionBuilder,
    (
      ExchangeRate,
      BaseReferences<_$PiggyDatabase, $ExchangeRatesTable, ExchangeRate>
    ),
    ExchangeRate,
    PrefetchHooks Function()> {
  $$ExchangeRatesTableTableManager(
      _$PiggyDatabase db, $ExchangeRatesTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ExchangeRatesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ExchangeRatesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ExchangeRatesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> baseCurrency = const Value.absent(),
            Value<String> quoteCurrency = const Value.absent(),
            Value<String> rateDate = const Value.absent(),
            Value<String> rate = const Value.absent(),
            Value<String> source = const Value.absent(),
            Value<DateTime> fetchedAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              ExchangeRatesCompanion(
            baseCurrency: baseCurrency,
            quoteCurrency: quoteCurrency,
            rateDate: rateDate,
            rate: rate,
            source: source,
            fetchedAt: fetchedAt,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String baseCurrency,
            required String quoteCurrency,
            required String rateDate,
            required String rate,
            required String source,
            required DateTime fetchedAt,
            Value<int> rowid = const Value.absent(),
          }) =>
              ExchangeRatesCompanion.insert(
            baseCurrency: baseCurrency,
            quoteCurrency: quoteCurrency,
            rateDate: rateDate,
            rate: rate,
            source: source,
            fetchedAt: fetchedAt,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable<$ExchangeRatesTable, ExchangeRate>(table),
                    BaseReferences<_$PiggyDatabase, $ExchangeRatesTable,
                        ExchangeRate>(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$ExchangeRatesTableProcessedTableManager = ProcessedTableManager<
    _$PiggyDatabase,
    $ExchangeRatesTable,
    ExchangeRate,
    $$ExchangeRatesTableFilterComposer,
    $$ExchangeRatesTableOrderingComposer,
    $$ExchangeRatesTableAnnotationComposer,
    $$ExchangeRatesTableCreateCompanionBuilder,
    $$ExchangeRatesTableUpdateCompanionBuilder,
    (
      ExchangeRate,
      BaseReferences<_$PiggyDatabase, $ExchangeRatesTable, ExchangeRate>
    ),
    ExchangeRate,
    PrefetchHooks Function()>;
typedef $$ExchangeRateOverridesTableCreateCompanionBuilder
    = ExchangeRateOverridesCompanion Function({
  Value<int> id,
  Value<String?> syncId,
  required String baseCurrency,
  required String quoteCurrency,
  required String rate,
  Value<DateTime?> updatedAt,
});
typedef $$ExchangeRateOverridesTableUpdateCompanionBuilder
    = ExchangeRateOverridesCompanion Function({
  Value<int> id,
  Value<String?> syncId,
  Value<String> baseCurrency,
  Value<String> quoteCurrency,
  Value<String> rate,
  Value<DateTime?> updatedAt,
});

class $$ExchangeRateOverridesTableFilterComposer
    extends Composer<_$PiggyDatabase, $ExchangeRateOverridesTable> {
  $$ExchangeRateOverridesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get syncId => $composableBuilder(
      column: $table.syncId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get baseCurrency => $composableBuilder(
      column: $table.baseCurrency, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get quoteCurrency => $composableBuilder(
      column: $table.quoteCurrency, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get rate => $composableBuilder(
      column: $table.rate, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnFilters(column));
}

class $$ExchangeRateOverridesTableOrderingComposer
    extends Composer<_$PiggyDatabase, $ExchangeRateOverridesTable> {
  $$ExchangeRateOverridesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get syncId => $composableBuilder(
      column: $table.syncId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get baseCurrency => $composableBuilder(
      column: $table.baseCurrency,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get quoteCurrency => $composableBuilder(
      column: $table.quoteCurrency,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get rate => $composableBuilder(
      column: $table.rate, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnOrderings(column));
}

class $$ExchangeRateOverridesTableAnnotationComposer
    extends Composer<_$PiggyDatabase, $ExchangeRateOverridesTable> {
  $$ExchangeRateOverridesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get syncId =>
      $composableBuilder(column: $table.syncId, builder: (column) => column);

  GeneratedColumn<String> get baseCurrency => $composableBuilder(
      column: $table.baseCurrency, builder: (column) => column);

  GeneratedColumn<String> get quoteCurrency => $composableBuilder(
      column: $table.quoteCurrency, builder: (column) => column);

  GeneratedColumn<String> get rate =>
      $composableBuilder(column: $table.rate, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$ExchangeRateOverridesTableTableManager extends RootTableManager<
    _$PiggyDatabase,
    $ExchangeRateOverridesTable,
    ExchangeRateOverride,
    $$ExchangeRateOverridesTableFilterComposer,
    $$ExchangeRateOverridesTableOrderingComposer,
    $$ExchangeRateOverridesTableAnnotationComposer,
    $$ExchangeRateOverridesTableCreateCompanionBuilder,
    $$ExchangeRateOverridesTableUpdateCompanionBuilder,
    (
      ExchangeRateOverride,
      BaseReferences<_$PiggyDatabase, $ExchangeRateOverridesTable,
          ExchangeRateOverride>
    ),
    ExchangeRateOverride,
    PrefetchHooks Function()> {
  $$ExchangeRateOverridesTableTableManager(
      _$PiggyDatabase db, $ExchangeRateOverridesTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ExchangeRateOverridesTableFilterComposer(
                  $db: db, $table: table),
          createOrderingComposer: () =>
              $$ExchangeRateOverridesTableOrderingComposer(
                  $db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ExchangeRateOverridesTableAnnotationComposer(
                  $db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String?> syncId = const Value.absent(),
            Value<String> baseCurrency = const Value.absent(),
            Value<String> quoteCurrency = const Value.absent(),
            Value<String> rate = const Value.absent(),
            Value<DateTime?> updatedAt = const Value.absent(),
          }) =>
              ExchangeRateOverridesCompanion(
            id: id,
            syncId: syncId,
            baseCurrency: baseCurrency,
            quoteCurrency: quoteCurrency,
            rate: rate,
            updatedAt: updatedAt,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String?> syncId = const Value.absent(),
            required String baseCurrency,
            required String quoteCurrency,
            required String rate,
            Value<DateTime?> updatedAt = const Value.absent(),
          }) =>
              ExchangeRateOverridesCompanion.insert(
            id: id,
            syncId: syncId,
            baseCurrency: baseCurrency,
            quoteCurrency: quoteCurrency,
            rate: rate,
            updatedAt: updatedAt,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable<$ExchangeRateOverridesTable,
                        ExchangeRateOverride>(table),
                    BaseReferences<_$PiggyDatabase, $ExchangeRateOverridesTable,
                        ExchangeRateOverride>(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$ExchangeRateOverridesTableProcessedTableManager
    = ProcessedTableManager<
        _$PiggyDatabase,
        $ExchangeRateOverridesTable,
        ExchangeRateOverride,
        $$ExchangeRateOverridesTableFilterComposer,
        $$ExchangeRateOverridesTableOrderingComposer,
        $$ExchangeRateOverridesTableAnnotationComposer,
        $$ExchangeRateOverridesTableCreateCompanionBuilder,
        $$ExchangeRateOverridesTableUpdateCompanionBuilder,
        (
          ExchangeRateOverride,
          BaseReferences<_$PiggyDatabase, $ExchangeRateOverridesTable,
              ExchangeRateOverride>
        ),
        ExchangeRateOverride,
        PrefetchHooks Function()>;
typedef $$EntityChangeWatermarksTableCreateCompanionBuilder
    = EntityChangeWatermarksCompanion Function({
  required String syncId,
  required int watermark,
  Value<int> rowid,
});
typedef $$EntityChangeWatermarksTableUpdateCompanionBuilder
    = EntityChangeWatermarksCompanion Function({
  Value<String> syncId,
  Value<int> watermark,
  Value<int> rowid,
});

class $$EntityChangeWatermarksTableFilterComposer
    extends Composer<_$PiggyDatabase, $EntityChangeWatermarksTable> {
  $$EntityChangeWatermarksTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get syncId => $composableBuilder(
      column: $table.syncId, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get watermark => $composableBuilder(
      column: $table.watermark, builder: (column) => ColumnFilters(column));
}

class $$EntityChangeWatermarksTableOrderingComposer
    extends Composer<_$PiggyDatabase, $EntityChangeWatermarksTable> {
  $$EntityChangeWatermarksTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get syncId => $composableBuilder(
      column: $table.syncId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get watermark => $composableBuilder(
      column: $table.watermark, builder: (column) => ColumnOrderings(column));
}

class $$EntityChangeWatermarksTableAnnotationComposer
    extends Composer<_$PiggyDatabase, $EntityChangeWatermarksTable> {
  $$EntityChangeWatermarksTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get syncId =>
      $composableBuilder(column: $table.syncId, builder: (column) => column);

  GeneratedColumn<int> get watermark =>
      $composableBuilder(column: $table.watermark, builder: (column) => column);
}

class $$EntityChangeWatermarksTableTableManager extends RootTableManager<
    _$PiggyDatabase,
    $EntityChangeWatermarksTable,
    EntityChangeWatermark,
    $$EntityChangeWatermarksTableFilterComposer,
    $$EntityChangeWatermarksTableOrderingComposer,
    $$EntityChangeWatermarksTableAnnotationComposer,
    $$EntityChangeWatermarksTableCreateCompanionBuilder,
    $$EntityChangeWatermarksTableUpdateCompanionBuilder,
    (
      EntityChangeWatermark,
      BaseReferences<_$PiggyDatabase, $EntityChangeWatermarksTable,
          EntityChangeWatermark>
    ),
    EntityChangeWatermark,
    PrefetchHooks Function()> {
  $$EntityChangeWatermarksTableTableManager(
      _$PiggyDatabase db, $EntityChangeWatermarksTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$EntityChangeWatermarksTableFilterComposer(
                  $db: db, $table: table),
          createOrderingComposer: () =>
              $$EntityChangeWatermarksTableOrderingComposer(
                  $db: db, $table: table),
          createComputedFieldComposer: () =>
              $$EntityChangeWatermarksTableAnnotationComposer(
                  $db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> syncId = const Value.absent(),
            Value<int> watermark = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              EntityChangeWatermarksCompanion(
            syncId: syncId,
            watermark: watermark,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String syncId,
            required int watermark,
            Value<int> rowid = const Value.absent(),
          }) =>
              EntityChangeWatermarksCompanion.insert(
            syncId: syncId,
            watermark: watermark,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable<$EntityChangeWatermarksTable,
                        EntityChangeWatermark>(table),
                    BaseReferences<
                        _$PiggyDatabase,
                        $EntityChangeWatermarksTable,
                        EntityChangeWatermark>(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$EntityChangeWatermarksTableProcessedTableManager
    = ProcessedTableManager<
        _$PiggyDatabase,
        $EntityChangeWatermarksTable,
        EntityChangeWatermark,
        $$EntityChangeWatermarksTableFilterComposer,
        $$EntityChangeWatermarksTableOrderingComposer,
        $$EntityChangeWatermarksTableAnnotationComposer,
        $$EntityChangeWatermarksTableCreateCompanionBuilder,
        $$EntityChangeWatermarksTableUpdateCompanionBuilder,
        (
          EntityChangeWatermark,
          BaseReferences<_$PiggyDatabase, $EntityChangeWatermarksTable,
              EntityChangeWatermark>
        ),
        EntityChangeWatermark,
        PrefetchHooks Function()>;
typedef $$SyncOpLogTableCreateCompanionBuilder = SyncOpLogCompanion Function({
  Value<int> id,
  Value<DateTime> ts,
  required String backend,
  required String scenario,
  required String outcome,
  Value<String?> errorClass,
  Value<int?> ledgerId,
  Value<int> attempts,
  Value<int?> durationMs,
});
typedef $$SyncOpLogTableUpdateCompanionBuilder = SyncOpLogCompanion Function({
  Value<int> id,
  Value<DateTime> ts,
  Value<String> backend,
  Value<String> scenario,
  Value<String> outcome,
  Value<String?> errorClass,
  Value<int?> ledgerId,
  Value<int> attempts,
  Value<int?> durationMs,
});

class $$SyncOpLogTableFilterComposer
    extends Composer<_$PiggyDatabase, $SyncOpLogTable> {
  $$SyncOpLogTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get ts => $composableBuilder(
      column: $table.ts, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get backend => $composableBuilder(
      column: $table.backend, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get scenario => $composableBuilder(
      column: $table.scenario, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get outcome => $composableBuilder(
      column: $table.outcome, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get errorClass => $composableBuilder(
      column: $table.errorClass, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get ledgerId => $composableBuilder(
      column: $table.ledgerId, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get attempts => $composableBuilder(
      column: $table.attempts, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get durationMs => $composableBuilder(
      column: $table.durationMs, builder: (column) => ColumnFilters(column));
}

class $$SyncOpLogTableOrderingComposer
    extends Composer<_$PiggyDatabase, $SyncOpLogTable> {
  $$SyncOpLogTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get ts => $composableBuilder(
      column: $table.ts, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get backend => $composableBuilder(
      column: $table.backend, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get scenario => $composableBuilder(
      column: $table.scenario, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get outcome => $composableBuilder(
      column: $table.outcome, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get errorClass => $composableBuilder(
      column: $table.errorClass, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get ledgerId => $composableBuilder(
      column: $table.ledgerId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get attempts => $composableBuilder(
      column: $table.attempts, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get durationMs => $composableBuilder(
      column: $table.durationMs, builder: (column) => ColumnOrderings(column));
}

class $$SyncOpLogTableAnnotationComposer
    extends Composer<_$PiggyDatabase, $SyncOpLogTable> {
  $$SyncOpLogTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<DateTime> get ts =>
      $composableBuilder(column: $table.ts, builder: (column) => column);

  GeneratedColumn<String> get backend =>
      $composableBuilder(column: $table.backend, builder: (column) => column);

  GeneratedColumn<String> get scenario =>
      $composableBuilder(column: $table.scenario, builder: (column) => column);

  GeneratedColumn<String> get outcome =>
      $composableBuilder(column: $table.outcome, builder: (column) => column);

  GeneratedColumn<String> get errorClass => $composableBuilder(
      column: $table.errorClass, builder: (column) => column);

  GeneratedColumn<int> get ledgerId =>
      $composableBuilder(column: $table.ledgerId, builder: (column) => column);

  GeneratedColumn<int> get attempts =>
      $composableBuilder(column: $table.attempts, builder: (column) => column);

  GeneratedColumn<int> get durationMs => $composableBuilder(
      column: $table.durationMs, builder: (column) => column);
}

class $$SyncOpLogTableTableManager extends RootTableManager<
    _$PiggyDatabase,
    $SyncOpLogTable,
    SyncOpLogData,
    $$SyncOpLogTableFilterComposer,
    $$SyncOpLogTableOrderingComposer,
    $$SyncOpLogTableAnnotationComposer,
    $$SyncOpLogTableCreateCompanionBuilder,
    $$SyncOpLogTableUpdateCompanionBuilder,
    (
      SyncOpLogData,
      BaseReferences<_$PiggyDatabase, $SyncOpLogTable, SyncOpLogData>
    ),
    SyncOpLogData,
    PrefetchHooks Function()> {
  $$SyncOpLogTableTableManager(_$PiggyDatabase db, $SyncOpLogTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SyncOpLogTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SyncOpLogTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SyncOpLogTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<DateTime> ts = const Value.absent(),
            Value<String> backend = const Value.absent(),
            Value<String> scenario = const Value.absent(),
            Value<String> outcome = const Value.absent(),
            Value<String?> errorClass = const Value.absent(),
            Value<int?> ledgerId = const Value.absent(),
            Value<int> attempts = const Value.absent(),
            Value<int?> durationMs = const Value.absent(),
          }) =>
              SyncOpLogCompanion(
            id: id,
            ts: ts,
            backend: backend,
            scenario: scenario,
            outcome: outcome,
            errorClass: errorClass,
            ledgerId: ledgerId,
            attempts: attempts,
            durationMs: durationMs,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<DateTime> ts = const Value.absent(),
            required String backend,
            required String scenario,
            required String outcome,
            Value<String?> errorClass = const Value.absent(),
            Value<int?> ledgerId = const Value.absent(),
            Value<int> attempts = const Value.absent(),
            Value<int?> durationMs = const Value.absent(),
          }) =>
              SyncOpLogCompanion.insert(
            id: id,
            ts: ts,
            backend: backend,
            scenario: scenario,
            outcome: outcome,
            errorClass: errorClass,
            ledgerId: ledgerId,
            attempts: attempts,
            durationMs: durationMs,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable<$SyncOpLogTable, SyncOpLogData>(table),
                    BaseReferences<_$PiggyDatabase, $SyncOpLogTable,
                        SyncOpLogData>(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$SyncOpLogTableProcessedTableManager = ProcessedTableManager<
    _$PiggyDatabase,
    $SyncOpLogTable,
    SyncOpLogData,
    $$SyncOpLogTableFilterComposer,
    $$SyncOpLogTableOrderingComposer,
    $$SyncOpLogTableAnnotationComposer,
    $$SyncOpLogTableCreateCompanionBuilder,
    $$SyncOpLogTableUpdateCompanionBuilder,
    (
      SyncOpLogData,
      BaseReferences<_$PiggyDatabase, $SyncOpLogTable, SyncOpLogData>
    ),
    SyncOpLogData,
    PrefetchHooks Function()>;
typedef $$StaleRemoteSlotsTableCreateCompanionBuilder
    = StaleRemoteSlotsCompanion Function({
  required String path,
  Value<DateTime> createdAt,
  Value<int> rowid,
});
typedef $$StaleRemoteSlotsTableUpdateCompanionBuilder
    = StaleRemoteSlotsCompanion Function({
  Value<String> path,
  Value<DateTime> createdAt,
  Value<int> rowid,
});

class $$StaleRemoteSlotsTableFilterComposer
    extends Composer<_$PiggyDatabase, $StaleRemoteSlotsTable> {
  $$StaleRemoteSlotsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get path => $composableBuilder(
      column: $table.path, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));
}

class $$StaleRemoteSlotsTableOrderingComposer
    extends Composer<_$PiggyDatabase, $StaleRemoteSlotsTable> {
  $$StaleRemoteSlotsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get path => $composableBuilder(
      column: $table.path, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));
}

class $$StaleRemoteSlotsTableAnnotationComposer
    extends Composer<_$PiggyDatabase, $StaleRemoteSlotsTable> {
  $$StaleRemoteSlotsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get path =>
      $composableBuilder(column: $table.path, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);
}

class $$StaleRemoteSlotsTableTableManager extends RootTableManager<
    _$PiggyDatabase,
    $StaleRemoteSlotsTable,
    StaleRemoteSlot,
    $$StaleRemoteSlotsTableFilterComposer,
    $$StaleRemoteSlotsTableOrderingComposer,
    $$StaleRemoteSlotsTableAnnotationComposer,
    $$StaleRemoteSlotsTableCreateCompanionBuilder,
    $$StaleRemoteSlotsTableUpdateCompanionBuilder,
    (
      StaleRemoteSlot,
      BaseReferences<_$PiggyDatabase, $StaleRemoteSlotsTable, StaleRemoteSlot>
    ),
    StaleRemoteSlot,
    PrefetchHooks Function()> {
  $$StaleRemoteSlotsTableTableManager(
      _$PiggyDatabase db, $StaleRemoteSlotsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$StaleRemoteSlotsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$StaleRemoteSlotsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$StaleRemoteSlotsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> path = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              StaleRemoteSlotsCompanion(
            path: path,
            createdAt: createdAt,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String path,
            Value<DateTime> createdAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              StaleRemoteSlotsCompanion.insert(
            path: path,
            createdAt: createdAt,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable<$StaleRemoteSlotsTable, StaleRemoteSlot>(table),
                    BaseReferences<_$PiggyDatabase, $StaleRemoteSlotsTable,
                        StaleRemoteSlot>(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$StaleRemoteSlotsTableProcessedTableManager = ProcessedTableManager<
    _$PiggyDatabase,
    $StaleRemoteSlotsTable,
    StaleRemoteSlot,
    $$StaleRemoteSlotsTableFilterComposer,
    $$StaleRemoteSlotsTableOrderingComposer,
    $$StaleRemoteSlotsTableAnnotationComposer,
    $$StaleRemoteSlotsTableCreateCompanionBuilder,
    $$StaleRemoteSlotsTableUpdateCompanionBuilder,
    (
      StaleRemoteSlot,
      BaseReferences<_$PiggyDatabase, $StaleRemoteSlotsTable, StaleRemoteSlot>
    ),
    StaleRemoteSlot,
    PrefetchHooks Function()>;
typedef $$DeletedTransactionsTableCreateCompanionBuilder
    = DeletedTransactionsCompanion Function({
  Value<int> txId,
  required int ledgerId,
  Value<String?> syncId,
  required DateTime happenedAt,
  required DateTime deletedAt,
  required String payload,
});
typedef $$DeletedTransactionsTableUpdateCompanionBuilder
    = DeletedTransactionsCompanion Function({
  Value<int> txId,
  Value<int> ledgerId,
  Value<String?> syncId,
  Value<DateTime> happenedAt,
  Value<DateTime> deletedAt,
  Value<String> payload,
});

class $$DeletedTransactionsTableFilterComposer
    extends Composer<_$PiggyDatabase, $DeletedTransactionsTable> {
  $$DeletedTransactionsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get txId => $composableBuilder(
      column: $table.txId, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get ledgerId => $composableBuilder(
      column: $table.ledgerId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get syncId => $composableBuilder(
      column: $table.syncId, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get happenedAt => $composableBuilder(
      column: $table.happenedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get deletedAt => $composableBuilder(
      column: $table.deletedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get payload => $composableBuilder(
      column: $table.payload, builder: (column) => ColumnFilters(column));
}

class $$DeletedTransactionsTableOrderingComposer
    extends Composer<_$PiggyDatabase, $DeletedTransactionsTable> {
  $$DeletedTransactionsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get txId => $composableBuilder(
      column: $table.txId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get ledgerId => $composableBuilder(
      column: $table.ledgerId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get syncId => $composableBuilder(
      column: $table.syncId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get happenedAt => $composableBuilder(
      column: $table.happenedAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get deletedAt => $composableBuilder(
      column: $table.deletedAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get payload => $composableBuilder(
      column: $table.payload, builder: (column) => ColumnOrderings(column));
}

class $$DeletedTransactionsTableAnnotationComposer
    extends Composer<_$PiggyDatabase, $DeletedTransactionsTable> {
  $$DeletedTransactionsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get txId =>
      $composableBuilder(column: $table.txId, builder: (column) => column);

  GeneratedColumn<int> get ledgerId =>
      $composableBuilder(column: $table.ledgerId, builder: (column) => column);

  GeneratedColumn<String> get syncId =>
      $composableBuilder(column: $table.syncId, builder: (column) => column);

  GeneratedColumn<DateTime> get happenedAt => $composableBuilder(
      column: $table.happenedAt, builder: (column) => column);

  GeneratedColumn<DateTime> get deletedAt =>
      $composableBuilder(column: $table.deletedAt, builder: (column) => column);

  GeneratedColumn<String> get payload =>
      $composableBuilder(column: $table.payload, builder: (column) => column);
}

class $$DeletedTransactionsTableTableManager extends RootTableManager<
    _$PiggyDatabase,
    $DeletedTransactionsTable,
    DeletedTransaction,
    $$DeletedTransactionsTableFilterComposer,
    $$DeletedTransactionsTableOrderingComposer,
    $$DeletedTransactionsTableAnnotationComposer,
    $$DeletedTransactionsTableCreateCompanionBuilder,
    $$DeletedTransactionsTableUpdateCompanionBuilder,
    (
      DeletedTransaction,
      BaseReferences<_$PiggyDatabase, $DeletedTransactionsTable,
          DeletedTransaction>
    ),
    DeletedTransaction,
    PrefetchHooks Function()> {
  $$DeletedTransactionsTableTableManager(
      _$PiggyDatabase db, $DeletedTransactionsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$DeletedTransactionsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$DeletedTransactionsTableOrderingComposer(
                  $db: db, $table: table),
          createComputedFieldComposer: () =>
              $$DeletedTransactionsTableAnnotationComposer(
                  $db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> txId = const Value.absent(),
            Value<int> ledgerId = const Value.absent(),
            Value<String?> syncId = const Value.absent(),
            Value<DateTime> happenedAt = const Value.absent(),
            Value<DateTime> deletedAt = const Value.absent(),
            Value<String> payload = const Value.absent(),
          }) =>
              DeletedTransactionsCompanion(
            txId: txId,
            ledgerId: ledgerId,
            syncId: syncId,
            happenedAt: happenedAt,
            deletedAt: deletedAt,
            payload: payload,
          ),
          createCompanionCallback: ({
            Value<int> txId = const Value.absent(),
            required int ledgerId,
            Value<String?> syncId = const Value.absent(),
            required DateTime happenedAt,
            required DateTime deletedAt,
            required String payload,
          }) =>
              DeletedTransactionsCompanion.insert(
            txId: txId,
            ledgerId: ledgerId,
            syncId: syncId,
            happenedAt: happenedAt,
            deletedAt: deletedAt,
            payload: payload,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable<$DeletedTransactionsTable, DeletedTransaction>(
                        table),
                    BaseReferences<_$PiggyDatabase, $DeletedTransactionsTable,
                        DeletedTransaction>(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$DeletedTransactionsTableProcessedTableManager = ProcessedTableManager<
    _$PiggyDatabase,
    $DeletedTransactionsTable,
    DeletedTransaction,
    $$DeletedTransactionsTableFilterComposer,
    $$DeletedTransactionsTableOrderingComposer,
    $$DeletedTransactionsTableAnnotationComposer,
    $$DeletedTransactionsTableCreateCompanionBuilder,
    $$DeletedTransactionsTableUpdateCompanionBuilder,
    (
      DeletedTransaction,
      BaseReferences<_$PiggyDatabase, $DeletedTransactionsTable,
          DeletedTransaction>
    ),
    DeletedTransaction,
    PrefetchHooks Function()>;
typedef $$HolidayEntriesTableCreateCompanionBuilder = HolidayEntriesCompanion
    Function({
  required String date,
  required int year,
  required bool isHoliday,
  required String name,
  required DateTime fetchedAt,
  Value<int> rowid,
});
typedef $$HolidayEntriesTableUpdateCompanionBuilder = HolidayEntriesCompanion
    Function({
  Value<String> date,
  Value<int> year,
  Value<bool> isHoliday,
  Value<String> name,
  Value<DateTime> fetchedAt,
  Value<int> rowid,
});

class $$HolidayEntriesTableFilterComposer
    extends Composer<_$PiggyDatabase, $HolidayEntriesTable> {
  $$HolidayEntriesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get date => $composableBuilder(
      column: $table.date, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get year => $composableBuilder(
      column: $table.year, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get isHoliday => $composableBuilder(
      column: $table.isHoliday, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get fetchedAt => $composableBuilder(
      column: $table.fetchedAt, builder: (column) => ColumnFilters(column));
}

class $$HolidayEntriesTableOrderingComposer
    extends Composer<_$PiggyDatabase, $HolidayEntriesTable> {
  $$HolidayEntriesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get date => $composableBuilder(
      column: $table.date, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get year => $composableBuilder(
      column: $table.year, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get isHoliday => $composableBuilder(
      column: $table.isHoliday, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get fetchedAt => $composableBuilder(
      column: $table.fetchedAt, builder: (column) => ColumnOrderings(column));
}

class $$HolidayEntriesTableAnnotationComposer
    extends Composer<_$PiggyDatabase, $HolidayEntriesTable> {
  $$HolidayEntriesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get date =>
      $composableBuilder(column: $table.date, builder: (column) => column);

  GeneratedColumn<int> get year =>
      $composableBuilder(column: $table.year, builder: (column) => column);

  GeneratedColumn<bool> get isHoliday =>
      $composableBuilder(column: $table.isHoliday, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<DateTime> get fetchedAt =>
      $composableBuilder(column: $table.fetchedAt, builder: (column) => column);
}

class $$HolidayEntriesTableTableManager extends RootTableManager<
    _$PiggyDatabase,
    $HolidayEntriesTable,
    HolidayEntry,
    $$HolidayEntriesTableFilterComposer,
    $$HolidayEntriesTableOrderingComposer,
    $$HolidayEntriesTableAnnotationComposer,
    $$HolidayEntriesTableCreateCompanionBuilder,
    $$HolidayEntriesTableUpdateCompanionBuilder,
    (
      HolidayEntry,
      BaseReferences<_$PiggyDatabase, $HolidayEntriesTable, HolidayEntry>
    ),
    HolidayEntry,
    PrefetchHooks Function()> {
  $$HolidayEntriesTableTableManager(
      _$PiggyDatabase db, $HolidayEntriesTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$HolidayEntriesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$HolidayEntriesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$HolidayEntriesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> date = const Value.absent(),
            Value<int> year = const Value.absent(),
            Value<bool> isHoliday = const Value.absent(),
            Value<String> name = const Value.absent(),
            Value<DateTime> fetchedAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              HolidayEntriesCompanion(
            date: date,
            year: year,
            isHoliday: isHoliday,
            name: name,
            fetchedAt: fetchedAt,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String date,
            required int year,
            required bool isHoliday,
            required String name,
            required DateTime fetchedAt,
            Value<int> rowid = const Value.absent(),
          }) =>
              HolidayEntriesCompanion.insert(
            date: date,
            year: year,
            isHoliday: isHoliday,
            name: name,
            fetchedAt: fetchedAt,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable<$HolidayEntriesTable, HolidayEntry>(table),
                    BaseReferences<_$PiggyDatabase, $HolidayEntriesTable,
                        HolidayEntry>(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$HolidayEntriesTableProcessedTableManager = ProcessedTableManager<
    _$PiggyDatabase,
    $HolidayEntriesTable,
    HolidayEntry,
    $$HolidayEntriesTableFilterComposer,
    $$HolidayEntriesTableOrderingComposer,
    $$HolidayEntriesTableAnnotationComposer,
    $$HolidayEntriesTableCreateCompanionBuilder,
    $$HolidayEntriesTableUpdateCompanionBuilder,
    (
      HolidayEntry,
      BaseReferences<_$PiggyDatabase, $HolidayEntriesTable, HolidayEntry>
    ),
    HolidayEntry,
    PrefetchHooks Function()>;
typedef $$HolidayUpdateMetaTableCreateCompanionBuilder
    = HolidayUpdateMetaCompanion Function({
  Value<int> id,
  Value<int> lastUpdateMs,
  Value<int> lastAttemptMs,
  Value<int> failureCount,
  Value<bool> autoEnabled,
  required DateTime updatedAt,
});
typedef $$HolidayUpdateMetaTableUpdateCompanionBuilder
    = HolidayUpdateMetaCompanion Function({
  Value<int> id,
  Value<int> lastUpdateMs,
  Value<int> lastAttemptMs,
  Value<int> failureCount,
  Value<bool> autoEnabled,
  Value<DateTime> updatedAt,
});

class $$HolidayUpdateMetaTableFilterComposer
    extends Composer<_$PiggyDatabase, $HolidayUpdateMetaTable> {
  $$HolidayUpdateMetaTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get lastUpdateMs => $composableBuilder(
      column: $table.lastUpdateMs, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get lastAttemptMs => $composableBuilder(
      column: $table.lastAttemptMs, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get failureCount => $composableBuilder(
      column: $table.failureCount, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get autoEnabled => $composableBuilder(
      column: $table.autoEnabled, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnFilters(column));
}

class $$HolidayUpdateMetaTableOrderingComposer
    extends Composer<_$PiggyDatabase, $HolidayUpdateMetaTable> {
  $$HolidayUpdateMetaTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get lastUpdateMs => $composableBuilder(
      column: $table.lastUpdateMs,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get lastAttemptMs => $composableBuilder(
      column: $table.lastAttemptMs,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get failureCount => $composableBuilder(
      column: $table.failureCount,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get autoEnabled => $composableBuilder(
      column: $table.autoEnabled, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnOrderings(column));
}

class $$HolidayUpdateMetaTableAnnotationComposer
    extends Composer<_$PiggyDatabase, $HolidayUpdateMetaTable> {
  $$HolidayUpdateMetaTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get lastUpdateMs => $composableBuilder(
      column: $table.lastUpdateMs, builder: (column) => column);

  GeneratedColumn<int> get lastAttemptMs => $composableBuilder(
      column: $table.lastAttemptMs, builder: (column) => column);

  GeneratedColumn<int> get failureCount => $composableBuilder(
      column: $table.failureCount, builder: (column) => column);

  GeneratedColumn<bool> get autoEnabled => $composableBuilder(
      column: $table.autoEnabled, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$HolidayUpdateMetaTableTableManager extends RootTableManager<
    _$PiggyDatabase,
    $HolidayUpdateMetaTable,
    HolidayUpdateMetaData,
    $$HolidayUpdateMetaTableFilterComposer,
    $$HolidayUpdateMetaTableOrderingComposer,
    $$HolidayUpdateMetaTableAnnotationComposer,
    $$HolidayUpdateMetaTableCreateCompanionBuilder,
    $$HolidayUpdateMetaTableUpdateCompanionBuilder,
    (
      HolidayUpdateMetaData,
      BaseReferences<_$PiggyDatabase, $HolidayUpdateMetaTable,
          HolidayUpdateMetaData>
    ),
    HolidayUpdateMetaData,
    PrefetchHooks Function()> {
  $$HolidayUpdateMetaTableTableManager(
      _$PiggyDatabase db, $HolidayUpdateMetaTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$HolidayUpdateMetaTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$HolidayUpdateMetaTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$HolidayUpdateMetaTableAnnotationComposer(
                  $db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<int> lastUpdateMs = const Value.absent(),
            Value<int> lastAttemptMs = const Value.absent(),
            Value<int> failureCount = const Value.absent(),
            Value<bool> autoEnabled = const Value.absent(),
            Value<DateTime> updatedAt = const Value.absent(),
          }) =>
              HolidayUpdateMetaCompanion(
            id: id,
            lastUpdateMs: lastUpdateMs,
            lastAttemptMs: lastAttemptMs,
            failureCount: failureCount,
            autoEnabled: autoEnabled,
            updatedAt: updatedAt,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<int> lastUpdateMs = const Value.absent(),
            Value<int> lastAttemptMs = const Value.absent(),
            Value<int> failureCount = const Value.absent(),
            Value<bool> autoEnabled = const Value.absent(),
            required DateTime updatedAt,
          }) =>
              HolidayUpdateMetaCompanion.insert(
            id: id,
            lastUpdateMs: lastUpdateMs,
            lastAttemptMs: lastAttemptMs,
            failureCount: failureCount,
            autoEnabled: autoEnabled,
            updatedAt: updatedAt,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable<$HolidayUpdateMetaTable, HolidayUpdateMetaData>(
                        table),
                    BaseReferences<_$PiggyDatabase, $HolidayUpdateMetaTable,
                        HolidayUpdateMetaData>(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$HolidayUpdateMetaTableProcessedTableManager = ProcessedTableManager<
    _$PiggyDatabase,
    $HolidayUpdateMetaTable,
    HolidayUpdateMetaData,
    $$HolidayUpdateMetaTableFilterComposer,
    $$HolidayUpdateMetaTableOrderingComposer,
    $$HolidayUpdateMetaTableAnnotationComposer,
    $$HolidayUpdateMetaTableCreateCompanionBuilder,
    $$HolidayUpdateMetaTableUpdateCompanionBuilder,
    (
      HolidayUpdateMetaData,
      BaseReferences<_$PiggyDatabase, $HolidayUpdateMetaTable,
          HolidayUpdateMetaData>
    ),
    HolidayUpdateMetaData,
    PrefetchHooks Function()>;

class $PiggyDatabaseManager {
  final _$PiggyDatabase _db;
  $PiggyDatabaseManager(this._db);
  $$LedgersTableTableManager get ledgers =>
      $$LedgersTableTableManager(_db, _db.ledgers);
  $$AccountsTableTableManager get accounts =>
      $$AccountsTableTableManager(_db, _db.accounts);
  $$HoldingsTableTableManager get holdings =>
      $$HoldingsTableTableManager(_db, _db.holdings);
  $$CategoriesTableTableManager get categories =>
      $$CategoriesTableTableManager(_db, _db.categories);
  $$TransactionsTableTableManager get transactions =>
      $$TransactionsTableTableManager(_db, _db.transactions);
  $$RecurringTransactionsTableTableManager get recurringTransactions =>
      $$RecurringTransactionsTableTableManager(_db, _db.recurringTransactions);
  $$ConversationsTableTableManager get conversations =>
      $$ConversationsTableTableManager(_db, _db.conversations);
  $$MessagesTableTableManager get messages =>
      $$MessagesTableTableManager(_db, _db.messages);
  $$TagsTableTableManager get tags => $$TagsTableTableManager(_db, _db.tags);
  $$CustomFieldDefinitionsTableTableManager get customFieldDefinitions =>
      $$CustomFieldDefinitionsTableTableManager(
          _db, _db.customFieldDefinitions);
  $$TransactionTagsTableTableManager get transactionTags =>
      $$TransactionTagsTableTableManager(_db, _db.transactionTags);
  $$BudgetsTableTableManager get budgets =>
      $$BudgetsTableTableManager(_db, _db.budgets);
  $$SavingsGoalsTableTableManager get savingsGoals =>
      $$SavingsGoalsTableTableManager(_db, _db.savingsGoals);
  $$TransactionAttachmentsTableTableManager get transactionAttachments =>
      $$TransactionAttachmentsTableTableManager(
          _db, _db.transactionAttachments);
  $$LocalChangesTableTableManager get localChanges =>
      $$LocalChangesTableTableManager(_db, _db.localChanges);
  $$SyncPullErrorsTableTableManager get syncPullErrors =>
      $$SyncPullErrorsTableTableManager(_db, _db.syncPullErrors);
  $$ExchangeRatesTableTableManager get exchangeRates =>
      $$ExchangeRatesTableTableManager(_db, _db.exchangeRates);
  $$ExchangeRateOverridesTableTableManager get exchangeRateOverrides =>
      $$ExchangeRateOverridesTableTableManager(_db, _db.exchangeRateOverrides);
  $$EntityChangeWatermarksTableTableManager get entityChangeWatermarks =>
      $$EntityChangeWatermarksTableTableManager(
          _db, _db.entityChangeWatermarks);
  $$SyncOpLogTableTableManager get syncOpLog =>
      $$SyncOpLogTableTableManager(_db, _db.syncOpLog);
  $$StaleRemoteSlotsTableTableManager get staleRemoteSlots =>
      $$StaleRemoteSlotsTableTableManager(_db, _db.staleRemoteSlots);
  $$DeletedTransactionsTableTableManager get deletedTransactions =>
      $$DeletedTransactionsTableTableManager(_db, _db.deletedTransactions);
  $$HolidayEntriesTableTableManager get holidayEntries =>
      $$HolidayEntriesTableTableManager(_db, _db.holidayEntries);
  $$HolidayUpdateMetaTableTableManager get holidayUpdateMeta =>
      $$HolidayUpdateMetaTableTableManager(_db, _db.holidayUpdateMeta);
}
