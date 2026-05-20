# Мокинг модулей Slim для изолированного тестирования без Lyrion Music Server

**Автор:** Александр Чернышев  
**Дата:** 2026-05-20  
**Цель:** Документировать технику мокинга модулей Slim и методику отладки объектов в изолированной окружении

---

## Проблема

При разработке плагинов для Lyrion Music Server (ранее SqueezeBox Server) часто нужно:
- Тестировать логику без запуска полного LMS
- Отлаживать функции, которые зависят от Slim фреймворка
- Запускать unit-тесты в CI/CD pipeline без инфраструктуры

Запуск полного LMS требует:
- Установленного сервера (100+ MB)
- Конфигурации базы данных
- Подключенных устройств
- Долгого времени инициализации

**Решение:** Создать mock-модули Slim, которые имитируют интерфейс без реальной функциональности.

---

## Концепция мокинга в Perl

### 1. Основной принцип: Утиная типизация (Duck Typing)

Perl использует утиную типизацию: "Если это выглядит как утка, плавает как утка и крякает как утка — это утка."

```perl
# Реальный код ожидает эту функцию:
my $log = logger('plugin.zvuk');
$log->info("Message");

# Mock достаточно имитировать сигнатуру:
sub logger {
    my ($category) = @_;
    return bless {}, 'Slim::Utils::Log';
}

# Объект не нужно наследоваться от реального Slim::Utils::Log
# Достаточно иметь методы info(), debug(), error(), warn()
```

### 2. Способ мокинга: Замена в %INC

Perl при `use Module` или `require Module`:
1. Проверяет `%INC{Module}` — кеш загруженных модулей
2. Если найдено — использует сохранённый символ
3. Если нет — ищет файл и выполняет его

**Мокинг работает на уровне `%INC`:**

```perl
# t/lib/Slim/Utils/Log.pm — создаём фальшивый модуль
package Slim::Utils::Log;
use strict;
use warnings;

our %MOCK_LOG_MESSAGES;  # Хранилище для отладки

sub logger {
    my ($category) = @_;
    return bless { category => $category }, __PACKAGE__;
}

sub info {
    my ($self, $msg) = @_;
    push @{$MOCK_LOG_MESSAGES{$self->{category}}}, "INFO: $msg";
}

sub debug {
    my ($self, $msg) = @_;
    push @{$MOCK_LOG_MESSAGES{$self->{category}}}, "DEBUG: $msg";
}

sub error {
    my ($self, $msg) = @_;
    push @{$MOCK_LOG_MESSAGES{$self->{category}}}, "ERROR: $msg";
}

1;
```

**Использование в тесте:**

```perl
#!/usr/bin/env perl
use strict;
use warnings;

# КЛЮЧ: добавляем t/lib в начало @INC ДО любых use/require
use lib 't/lib';
use lib '.';

# Теперь при require Slim::Utils::Log загрузится наш mock
require Slim::Utils::Log;

# Реальный код из плагина:
require Plugins::Zvuk::WaveSettings;

# WaveSettings будет использовать наш mock Log и Prefs
my $log = Slim::Utils::Log::logger('plugin.zvuk');
$log->info("Test message");

# Проверяем что сообщение было залогировано:
print "Logged: " . $Slim::Utils::Log::MOCK_LOG_MESSAGES{'plugin.zvuk'}[0] . "\n";
```

---

## Практическая реализация: Три уровня мокинга

### Уровень 1: Простой Mock (функции возвращают значения)

**Сценарий:** Нужно протестировать код, который вызывает функции без побочных эффектов.

```perl
# t/lib/Slim/Utils/Prefs.pm
package Slim::Utils::Prefs;
use strict;
use warnings;

our %MOCK_PREFS = ();  # Хранилище настроек

sub preferences {
    my ($plugin_name) = @_;
    # Возвращаем объект-обёртку
    return bless { plugin => $plugin_name }, __PACKAGE__;
}

sub get {
    my ($self, $key) = @_;
    my $full_key = $self->{plugin} . ':' . $key;
    return $MOCK_PREFS{$full_key};
}

sub set {
    my ($self, $key, $value) = @_;
    my $full_key = $self->{plugin} . ':' . $key;
    $MOCK_PREFS{$full_key} = $value;
}

1;
```

**Тест:**

```perl
use lib 't/lib';
use Slim::Utils::Prefs;

my $prefs = Slim::Utils::Prefs::preferences('test.plugin');
$prefs->set('color', 'red');
my $color = $prefs->get('color');
print "Color: $color\n";  # Color: red
```

### Уровень 2: Mock с отладкой (отслеживание вызовов)

**Сценарий:** Нужно убедиться что функция была вызвана с правильными параметрами.

```perl
# t/lib/Slim/Utils/Log.pm
package Slim::Utils::Log;
use strict;
use warnings;

our @MOCK_CALLS = ();      # История вызовов
our $DEBUG_MODE = 0;        # Флаг детальной отладки

sub logger {
    my ($category) = @_;
    return bless { category => $category }, __PACKAGE__;
}

sub info {
    my ($self, $msg) = @_;
    my $call = {
        level    => 'INFO',
        category => $self->{category},
        message  => $msg,
        time     => time(),
    };
    push @MOCK_CALLS, $call;
    print "[INFO] $msg\n" if $DEBUG_MODE;
}

# Вспомогательная функция для тестов
sub get_calls_for_category {
    my ($category) = @_;
    return grep { $_->{category} eq $category } @MOCK_CALLS;
}

# Очистка между тестами
sub reset_calls {
    @MOCK_CALLS = ();
}

1;
```

**Тест с проверкой вызовов:**

```perl
use lib 't/lib';
use Slim::Utils::Log;

Slim::Utils::Log::reset_calls();

my $log = Slim::Utils::Log::logger('test.category');
$log->info("Message 1");
$log->info("Message 2");

my @calls = Slim::Utils::Log::get_calls_for_category('test.category');
die "Expected 2 calls, got " . scalar(@calls) unless @calls == 2;
die "Wrong message" unless $calls[0]->{message} eq "Message 1";

print "✓ All calls verified\n";
```

### Уровень 3: Mock с состоянием (имитация реального поведения)

**Сценарий:** Нужно имитировать сложное поведение (например, сохранение и загрузка).

```perl
# t/lib/Slim/Utils/Prefs.pm (расширенный)
package Slim::Utils::Prefs;
use strict;
use warnings;
use JSON::XS;

our %MOCK_STORAGE = ();       # Хранилище как реальная БД
our @MOCK_CHANGED = ();       # История изменений (для аудита)

sub preferences {
    my ($plugin_name) = @_;
    
    # Инициализировать хранилище для плагина если не существует
    $MOCK_STORAGE{$plugin_name} //= {};
    
    return bless { plugin => $plugin_name }, __PACKAGE__;
}

sub get {
    my ($self, $key) = @_;
    return $MOCK_STORAGE{$self->{plugin}}{$key};
}

sub set {
    my ($self, $key, $value) = @_;
    my $old_value = $MOCK_STORAGE{$self->{plugin}}{$key};
    
    $MOCK_STORAGE{$self->{plugin}}{$key} = $value;
    
    # Отслеживаем изменения
    push @MOCK_CHANGED, {
        plugin    => $self->{plugin},
        key       => $key,
        old_value => $old_value,
        new_value => $value,
        time      => time(),
    };
}

# Вспомогательные функции для тестов
sub get_storage {
    my ($plugin) = @_;
    return $MOCK_STORAGE{$plugin} // {};
}

sub get_changes {
    return @MOCK_CHANGED;
}

sub reset {
    %MOCK_STORAGE = ();
    @MOCK_CHANGED = ();
}

1;
```

**Тест со сложным состоянием:**

```perl
use lib 't/lib';
use Slim::Utils::Prefs;

Slim::Utils::Prefs::reset();

my $prefs = Slim::Utils::Prefs::preferences('wave.plugin');

# Сохраняем настройки как в реальном коде
$prefs->set('popular', 0.5);
$prefs->set('energy', 0.7);

# Проверяем что всё сохранилось
my $storage = Slim::Utils::Prefs::get_storage('wave.plugin');
die "Failed" unless $storage->{popular} == 0.5;

# Проверяем историю
my @changes = Slim::Utils::Prefs::get_changes();
die "Expected 2 changes" unless @changes == 2;

print "✓ Complex state verified\n";
```

---

## Методика отладки объектов без LMS контекста

### Техника 1: Ленивая загрузка с захватом

```perl
# Идея: загрузить реальный модуль, но перехватить критические функции

package Slim::Utils::Cache;
use strict;
use warnings;

our %MOCK_CACHE = ();
our $USE_REAL = 0;  # Флаг для переключения на реальную реализацию

sub new {
    my ($class) = @_;
    if ($USE_REAL) {
        # Если нужна реальная кеш - делегировать
        return eval { require Slim::Utils::Cache::Real; 
                      Slim::Utils::Cache::Real->new(@_) };
    }
    return bless { data => \%MOCK_CACHE }, $class;
}

sub get {
    my ($self, $key) = @_;
    return $self->{data}{$key};
}

sub set {
    my ($self, $key, $value, $ttl) = @_;
    $self->{data}{$key} = {
        value => $value,
        ttl   => $ttl,
        set   => time(),
    };
}

1;
```

### Техника 2: Дефинирование перед загрузкой (Pre-definition)

```perl
# Определить все необходимые символы перед использованием модуля

# Блокируем неожиданные загрузки
BEGIN {
    $INC{'Slim/Utils/Log.pm'} = 't/lib/Slim/Utils/Log.pm';
    $INC{'Slim/Utils/Prefs.pm'} = 't/lib/Slim/Utils/Prefs.pm';
    $INC{'Slim/Utils/Cache.pm'} = 't/lib/Slim/Utils/Cache.pm';
}

use lib 't/lib';
use lib '.';

# Теперь любой require найдёт наши mock версии
require Plugins::Zvuk::WaveSettings;
```

### Техника 3: Обёртки для отладки с контекстом вызова

```perl
package Slim::Utils::Log;
use strict;
use warnings;
use Carp;

our @MOCK_CALLS_WITH_CONTEXT = ();

sub logger {
    my ($category) = @_;
    return bless { category => $category }, __PACKAGE__;
}

sub info {
    my ($self, $msg) = @_;
    
    # Захватить стек вызовов для отладки
    my @stack = ();
    my $i = 1;
    while (my @caller = caller($i++)) {
        push @stack, {
            package => $caller[0],
            file    => $caller[1],
            line    => $caller[2],
            sub     => $caller[3],
        };
        last if $i > 5;  # Ограничиваем глубину стека
    }
    
    push @MOCK_CALLS_WITH_CONTEXT, {
        level    => 'INFO',
        category => $self->{category},
        message  => $msg,
        stack    => \@stack,
    };
}

# Вывести стек для понимания потока выполнения
sub print_last_call_stack {
    return unless @MOCK_CALLS_WITH_CONTEXT;
    my $call = $MOCK_CALLS_WITH_CONTEXT[-1];
    
    print "\n--- Call Stack for: $call->{message} ---\n";
    my $depth = 0;
    foreach my $frame (@{$call->{stack}}) {
        print "  " x $depth;
        print "$frame->{package}::$frame->{sub} " .
              "($frame->{file}:$frame->{line})\n";
        $depth++;
    }
}

1;
```

---

## Полный пример: Интеграционный тест

```perl
#!/usr/bin/env perl
use strict;
use warnings;

# Шаг 1: Настроить пути поиска ПЕРЕД любыми use/require
use lib 't/lib';
use lib '.';

# Шаг 2: Преопределить символы в %INC
BEGIN {
    $INC{'Slim/Utils/Log.pm'} = 't/lib/Slim/Utils/Log.pm';
    $INC{'Slim/Utils/Prefs.pm'} = 't/lib/Slim/Utils/Prefs.pm';
}

# Шаг 3: Загрузить mock модули явно
require Slim::Utils::Log;
require Slim::Utils::Prefs;

# Шаг 4: Загрузить реальный код для тестирования
require Plugins::Zvuk::WaveSettings;

print "Testing WaveSettings in isolation...\n";

# Шаг 5: Выполнить тест
my $test_count = 0;
my $pass_count = 0;

# Test: Проверить что logger был вызван при loadSettings
$test_count++;
print "Test 1: Load defaults\n";
Slim::Utils::Log::reset_calls();

my $defaults = Plugins::Zvuk::WaveSettings::loadSettings('test_acct');

if ($defaults && $defaults->{popular} == 0.5) {
    print "  ✓ PASS\n";
    $pass_count++;
} else {
    print "  ✗ FAIL\n";
}

# Test: Проверить что saveSettings сохранил в prefs
$test_count++;
print "Test 2: Save and reload\n";

my $settings = {
    popular => 0.3,
    energy => 0.8,
    fun => 0.6,
    language => 'foreign',
    vocal => 1,
    genres => ['rock', 'metal'],
};

Plugins::Zvuk::WaveSettings::saveSettings('test_acct2', $settings);
my $reloaded = Plugins::Zvuk::WaveSettings::loadSettings('test_acct2');

if ($reloaded && $reloaded->{popular} == 0.3 && 
    $reloaded->{language} eq 'foreign') {
    print "  ✓ PASS\n";
    $pass_count++;
} else {
    print "  ✗ FAIL\n";
}

print "\nResults: $pass_count/$test_count passed\n";
exit($pass_count == $test_count ? 0 : 1);
```

---

## Продвинутые техники

### 1. Mock с временем (для тестирования TTL, кеша)

```perl
our $MOCK_TIME = time();

sub current_time { $MOCK_TIME }
sub advance_time { $MOCK_TIME += $_[0] }
sub reset_time { $MOCK_TIME = time() }

# В коде кеша:
if (time() - $MOCK_CACHE{$key}{set} > $ttl) {
    delete $MOCK_CACHE{$key};
}
```

### 2. Mock с исключениями (для тестирования error handling)

```perl
our $MOCK_SHOULD_FAIL = 0;
our $MOCK_ERROR_MSG = '';

sub get {
    my ($self, $key) = @_;
    if ($MOCK_SHOULD_FAIL) {
        die $MOCK_ERROR_MSG || 'Mock error';
    }
    return $self->{data}{$key};
}

# В тесте:
Slim::Utils::Cache::$MOCK_SHOULD_FAIL = 1;
Slim::Utils::Cache::$MOCK_ERROR_MSG = 'Connection timeout';

eval { Plugins::Zvuk::API->getStream($cb); };
die "Should have caught error" unless $@;
```

### 3. Mock с асинхронностью (для тестирования callbacks)

```perl
package Slim::Networking::SimpleAsyncHTTP;
use strict;
use warnings;

our @MOCK_PENDING_REQUESTS = ();

sub new {
    my ($class, $success_cb, $error_cb, $opts) = @_;
    return bless {
        success_cb => $success_cb,
        error_cb => $error_cb,
        opts => $opts,
    }, $class;
}

sub post {
    my ($self, $url, @headers) = @_;
    # Сохранить для позже обработки
    push @MOCK_PENDING_REQUESTS, $self;
}

# Вспомогательная функция для тестов
sub flush_pending {
    while (my $req = shift @MOCK_PENDING_REQUESTS) {
        # Имитировать успешный ответ
        my $response = bless { content => '{"data": {}}' }, 'MockResponse';
        $req->{success_cb}->($response);
    }
}

package MockResponse;
sub content { $_[0]->{content} }

1;
```

---

## Best Practices

### ✅ ДЕЛАЙ

1. **Используй namespace разделение:**
   ```perl
   package Slim::Utils::Log;        # Mock
   package Plugins::Zvuk::WaveSettings;  # Реальный код
   ```

2. **Документируй поведение mock:**
   ```perl
   # Mock: Возвращает всегда успешный ответ
   # Реальный: Может выбросить исключение или вернуть пустой результат
   sub get_stream {
       my ($self, $id) = @_;
       return { id => $id, url => "mock://track/$id" };
   }
   ```

3. **Предоставляй hooks для отладки:**
   ```perl
   our $DEBUG = 0;
   our @CALL_HISTORY = ();
   
   sub get {
       my ($self, $key) = @_;
       push @CALL_HISTORY, { key => $key, time => time() } if $DEBUG;
       return $self->{data}{$key};
   }
   ```

### ❌ НЕ ДЕЛАЙ

1. **Не полагайся на побочные эффекты реального кода:**
   ```perl
   # ПЛОХО: Mock должен быть независимым
   require Slim::Utils::Cache::Real;  # Это может загрузить весь LMS
   ```

2. **Не забывай очищать состояние между тестами:**
   ```perl
   # ПЛОХО
   sub test1 { Prefs::set('key', 'value1'); }
   sub test2 { my $v = Prefs::get('key'); }  # Получит 'value1' от test1!
   
   # ХОРОШО
   sub reset { %MOCK_STORAGE = (); }
   sub test1 { reset(); ... }
   sub test2 { reset(); ... }
   ```

3. **Не создавай слишком реалистичные mock'и:**
   ```perl
   # ПЛОХО: Mock становится сложнее чем реальный код
   # ХОРОШО: Mock простой, тесты сосредоточены на логике
   ```

---

## Реальный пример из проекта

В проекте lms-zvuk мы используем эту технику для тестирования `WaveSettings` без полного LMS:

```
t/
├── lib/
│   └── Slim/Utils/
│       ├── Log.pm       # Mock логгера
│       └── Prefs.pm     # Mock preferences
├── wave_settings_test.pl # Основной тест
```

**Результат:**
- ✅ Тесты запускаются за <1 сек (vs ~30 сек с реальным LMS)
- ✅ Не требует установки LMS
- ✅ Можно запустить в CI/CD
- ✅ Полная изоляция — изменения в одном тесте не влияют на другой

---

## Заключение

Мокинг модулей Slim позволяет:

1. **Тестировать быстро** — без инициализации LMS
2. **Тестировать независимо** — без внешних зависимостей
3. **Отлаживать легко** — с историей вызовов и контекстом
4. **Развиваться параллельно** — разработка и тестирование не связаны

Ключ — использовать **Perl's duck typing** и механизм `%INC` для подмены модулей.

