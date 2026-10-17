<?php
// Wavelog Helm chart bootstrap. Runs as an init container before Apache starts.
// Phases are plain functions; main() runs them in order.
// Every PHP value written into a config file goes through var_export().

const WL_DEFAULT_KEY = 'flossie1234555541';
const WL_APP_DIR = '/var/www/html';
const WL_TEMPLATE_DIR = WL_APP_DIR . '/install/config';
const WL_INSTALL_DIR = WL_APP_DIR . '/install';
const WL_SSO_SAMPLE = WL_APP_DIR . '/application/config/sso.sample.php';
// auth.header value => upstream sso.php key.
const WL_SSO_KEYS = [
    'jwksUri' => 'auth_header_jwks_uri',
    'headerName' => 'auth_header_accesstoken',
    'createUsers' => 'auth_header_create',
    'allowDirectLogin' => 'auth_header_allow_direct_login',
    'hidePasswordField' => 'auth_header_hide_password_field',
    'buttonText' => 'auth_header_text',
    'logoutUrl' => 'auth_header_url_logout',
];
// Claim-mapped user fields that stay editable in Wavelog's account form.
const WL_SSO_EDITABLE_CLAIMS = ['user_firstname', 'user_lastname'];

function fail(string $reason): void
{
    fwrite(STDERR, 'bootstrap: ' . str_replace(["\r", "\n"], ' ', $reason) . "\n");
    exit(1);
}

function info(string $message): void
{
    fwrite(STDOUT, 'bootstrap: ' . $message . "\n");
}

// Upstream's installer class logs through CodeIgniter's log_message(); forward
// its errors to stderr so a failed schema install says why.
function log_message(string $level, string $message): void
{
    if ($level === 'error') {
        fwrite(STDERR, 'bootstrap: installer: ' . str_replace(["\r", "\n"], ' ', $message) . "\n");
    }
}

function env(string $name, string $default = ''): string
{
    $v = getenv($name);
    return ($v === false) ? $default : $v;
}

function read_template(string $name): string
{
    $path = WL_TEMPLATE_DIR . '/' . $name;
    $s = @file_get_contents($path);
    if ($s === false) {
        fail("cannot read template $path");
    }
    return $s;
}

// Replace each quoted placeholder ('%name%', quotes included) with a PHP literal.
// The template's placeholders must match $values exactly. The check runs on the
// template, before substitution, so values that look like placeholders (e.g.
// '%b%') are fine; strtr() substitutes in one pass and never rescans a value.
function fill_template(string $tpl, array $values): string
{
    preg_match_all("/'%([A-Za-z_]+)%'/", $tpl, $m);
    $found = array_unique($m[1]);
    foreach (array_diff(array_keys($values), $found) as $name) {
        fail("placeholder '%$name%' not found in template");
    }
    foreach (array_diff($found, array_keys($values)) as $name) {
        fail("unfilled placeholder '%$name%' in template");
    }
    $pairs = [];
    foreach ($values as $name => $value) {
        $pairs["'%" . $name . "%'"] = var_export($value, true);
    }
    return strtr($tpl, $pairs);
}

// Write atomically with mode 0640 so Apache (group www-data) can read it.
function write_file(string $dir, string $name, string $content): void
{
    if (!is_dir($dir) || !is_writable($dir)) {
        fail("config directory $dir is not writable");
    }
    $tmp = $dir . '/.' . $name . '.tmp';
    $old = umask(0027);
    $ok = file_put_contents($tmp, $content) !== false;
    umask($old);
    if (!$ok || !chmod($tmp, 0640) || !rename($tmp, $dir . '/' . $name)) {
        @unlink($tmp);
        fail("cannot write $dir/$name");
    }
}

// Append $config[key] = value lines; later assignments override the template's.
function append_config(string $php, array $entries, string $source): string
{
    if (!$entries) {
        return $php;
    }
    $php = rtrim($php) . "\n\n// Added by the Helm chart ($source)\n";
    foreach ($entries as $k => $v) {
        $php .= '$config[' . var_export((string) $k, true) . '] = ' . var_export($v, true) . ";\n";
    }
    return $php;
}

function render_config(): void
{
    $dir = env('WL_CONFIG_DIR');
    if ($dir === '') {
        fail('WL_CONFIG_DIR is not set');
    }
    $key = env('WL_ENCRYPTION_KEY');
    if ($key === '' || $key === WL_DEFAULT_KEY) {
        fail('encryption key missing or default');
    }

    $callbook = env('WL_CALLBOOK', 'hamqth');
    $values = [
        'directory' => '',
        'callbook' => $callbook,
        'baselocator' => env('WL_LOCATOR'),
        'websiteurl' => env('WL_BASE_URL'),
        'log_threshold' => (int) env('WL_LOG_THRESHOLD', '1'),
        'encryptionkey' => $key,
        'qrzcall_token' => ($callbook === 'qrzcall') ? env('WL_QRZCALL_TOKEN') : '',
    ];
    foreach (['qrz', 'hamqth', 'qrzcq', 'qrzru'] as $provider) {
        $on = ($callbook === $provider);
        $values[$provider . '_username'] = $on ? env('WL_CALLBOOK_USERNAME') : '';
        $values[$provider . '_password'] = $on ? env('WL_CALLBOOK_PASSWORD') : '';
    }
    $config = fill_template(read_template('config.php'), $values);

    if (env('WL_AUTH_MODE', 'local') === 'header') {
        $flag = '$config[\'auth_header_enable\'] = false;';
        if (strpos($config, $flag) === false) {
            fail('auth_header_enable not found in config template');
        }
        $config = str_replace($flag, '$config[\'auth_header_enable\'] = true;', $config);
    }

    $extra = json_decode(env('WL_EXTRA_CONFIG_JSON', '{}') ?: '{}', true);
    if (!is_array($extra)) {
        fail('WL_EXTRA_CONFIG_JSON must be a JSON object');
    }
    $config = append_config($config, $extra, 'config.extra');

    // CodeIgniter's mysqli driver takes the port from 'port', not 'host:port'.
    $db = read_template('database.php');
    $hostLine = "'hostname' => '%HOSTNAME%',";
    if (strpos($db, $hostLine) === false) {
        fail('hostname placeholder not found in database template');
    }
    $db = str_replace($hostLine, $hostLine . "\n\t'port' => " . var_export((int) env('WL_DB_PORT', '3306'), true) . ',', $db);
    $db = fill_template($db, [
        'HOSTNAME' => env('WL_DB_HOST'),
        'USERNAME' => env('WL_DB_USER'),
        'PASSWORD' => env('WL_DB_PASSWORD'),
        'DATABASE' => env('WL_DB_NAME'),
    ]);

    write_file($dir, 'config.php', $config);
    write_file($dir, 'database.php', $db);
}

// sso.php for header auth: upstream's sample with each auth.header value set
// in place, then auth.header.extra appended verbatim by key.
function render_sso(): void
{
    $dir = env('WL_CONFIG_DIR');
    if ($dir === '') {
        fail('WL_CONFIG_DIR is not set');
    }
    $sso = json_decode(env('WL_SSO_JSON', '{}') ?: '{}', true);
    if (!is_array($sso)) {
        fail('WL_SSO_JSON must be a JSON object');
    }
    if ((string) ($sso['jwksUri'] ?? '') === '') {
        fail('auth.header.jwksUri is required when auth.mode=header');
    }
    $php = @file_get_contents(WL_SSO_SAMPLE);
    if ($php === false) {
        fail('cannot read ' . WL_SSO_SAMPLE);
    }
    foreach (WL_SSO_KEYS as $from => $key) {
        if (!array_key_exists($from, $sso)) {
            continue;
        }
        $line = '$config[' . var_export($key, true) . '] = ' . var_export($sso[$from], true) . ';';
        $php = preg_replace_callback(
            '/^\$config\[\'' . preg_quote($key, '/') . '\'\]\s*=[^\n]*;[ \t]*$/m',
            fn() => $line,
            $php,
            -1,
            $count
        );
        if ($count !== 1) {
            fail("$key not found once in sso.sample.php");
        }
    }
    // Wavelog requires a first and last name to save the account form, but the
    // sample locks both to claims many IdPs leave out of the access token. Keep
    // them editable; a claim that is present still overwrites them at login.
    $php = rtrim($php) . "\n\n// Added by the Helm chart (names stay editable)\n";
    foreach (WL_SSO_EDITABLE_CLAIMS as $field) {
        if (!preg_match('/^\s*\'' . preg_quote($field, '/') . '\'\s*=>/m', $php)) {
            fail("$field not found in sso.sample.php claim config");
        }
        $php .= '$config[\'auth_headers_claim_config\'][' . var_export($field, true) . "]['allow_manual_change'] = true;\n";
    }
    $extra = $sso['extra'] ?? [];
    if (!is_array($extra)) {
        fail('auth.header.extra must be a map');
    }
    // A mapped key in extra would override the dedicated value, e.g. an empty
    // auth_header_jwks_uri disables signature verification upstream.
    foreach (array_keys($extra) as $k) {
        if (in_array((string) $k, WL_SSO_KEYS, true)) {
            fail("auth.header.extra must not set $k; use the dedicated auth.header value");
        }
    }
    write_file($dir, 'sso.php', append_config($php, $extra, 'auth.header.extra'));
}

function db(): mysqli
{
    mysqli_report(MYSQLI_REPORT_ERROR | MYSQLI_REPORT_STRICT);
    $db = mysqli_init();
    $db->options(MYSQLI_OPT_CONNECT_TIMEOUT, 5);
    $db->real_connect(
        env('WL_DB_HOST'),
        env('WL_DB_USER'),
        env('WL_DB_PASSWORD'),
        env('WL_DB_NAME'),
        (int) env('WL_DB_PORT', '3306')
    );
    $db->set_charset('utf8mb4');
    return $db;
}

// Retry every 3 s until WL_DB_WAIT_SECONDS. Wrong credentials fail at once.
function wait_for_db(): mysqli
{
    $limit = (int) env('WL_DB_WAIT_SECONDS', '300');
    $deadline = time() + $limit;
    while (true) {
        try {
            return db();
        } catch (mysqli_sql_exception $e) {
            if (in_array($e->getCode(), [1044, 1045], true)) {
                fail('database login failed: ' . $e->getMessage());
            }
            if (time() >= $deadline) {
                fail("database not reachable after {$limit}s: " . $e->getMessage());
            }
            info('waiting for database (' . $e->getMessage() . ')');
            sleep(3);
        }
    }
}

function scalar(mysqli $db, string $sql): int
{
    return (int) $db->query($sql)->fetch_row()[0];
}

// installed: users has at least one row; empty: no tables; anything else: partial.
function install_state(mysqli $db): string
{
    $tables = scalar($db, 'SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE()');
    if ($tables === 0) {
        return 'empty';
    }
    $hasUsers = scalar($db, "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = 'users'");
    if ($hasUsers === 1 && scalar($db, 'SELECT COUNT(*) FROM users') >= 1) {
        return 'installed';
    }
    return 'partial';
}

// Runs upstream's own installer class (install/includes/core/database_class.php,
// Database::create_tables) so install.sql gets exactly upstream's escaping and
// password_hash substitution. Only call on an empty schema: install.sql drops
// and recreates every table.
function install_schema(): void
{
    $username = env('WL_ADMIN_USERNAME');
    $password = env('WL_ADMIN_PASSWORD');
    if ($username === '' || $password === '') {
        fail('admin username and password must not be empty');
    }
    require_once WL_INSTALL_DIR . '/includes/core/database_class.php';
    // create_tables() connects without a port argument and reads
    // 'assets/install.sql' relative to the installer directory.
    ini_set('mysqli.default_port', env('WL_DB_PORT', '3306'));
    if (!chdir(WL_INSTALL_DIR)) {
        fail('cannot enter ' . WL_INSTALL_DIR);
    }
    $ok = (new Database())->create_tables([
        'db_hostname' => env('WL_DB_HOST'),
        'db_username' => env('WL_DB_USER'),
        'db_password' => env('WL_DB_PASSWORD'),
        'db_name' => env('WL_DB_NAME'),
        'username' => $username,
        'password' => $password,
        'user_email' => env('WL_ADMIN_EMAIL'),
        'callsign' => env('WL_ADMIN_CALLSIGN'),
        'userlocator' => env('WL_ADMIN_LOCATOR'),
        'firstname' => env('WL_ADMIN_FIRSTNAME'),
        'lastname' => env('WL_ADMIN_LASTNAME'),
        'timezone' => env('WL_ADMIN_TIMEZONE', '0'),
        'dxcc' => env('WL_ADMIN_DXCC', '0'),
        'city' => env('WL_ADMIN_CITY'),
        'userlanguage' => env('WL_ADMIN_LANGUAGE', 'english'),
    ]);
    chdir('/');
    if (!$ok) {
        fail('schema install failed');
    }
}

// CodeIgniter accepts CLI requests, so the Migrate controller runs directly:
// `php index.php migrate` (CI_ENV=docker selects the rendered config). It
// prints {"status":"success","version":N}. Verified against Wavelog 3.2.4; the
// php -S fallback was not needed.
// Run a Wavelog controller from the command line (php index.php <segments>).
// Returns [exit code, combined output].
function run_wavelog_cli(string ...$segments): array
{
    $env = getenv();
    $env['CI_ENV'] = 'docker';
    $proc = proc_open(
        array_merge(
            [
                'php',
                // CI_ENV must reach getenv()/$_SERVER whatever php.ini says.
                '-d', 'variables_order=EGPCS',
                '-d', 'memory_limit=' . ini_get('memory_limit'),
                '-d', 'max_execution_time=' . ini_get('max_execution_time'),
                WL_APP_DIR . '/index.php',
            ],
            $segments
        ),
        [0 => ['file', '/dev/null', 'r'], 1 => ['pipe', 'w'], 2 => ['redirect', 1]],
        $pipes,
        WL_APP_DIR,
        $env
    );
    if (!is_resource($proc)) {
        fail('cannot start php index.php ' . implode(' ', $segments));
    }
    $out = stream_get_contents($pipes[1]);
    fclose($pipes[1]);
    return [proc_close($proc), $out];
}

function run_migrations(): void
{
    [$rc, $out] = run_wavelog_cli('migrate');
    if ($rc !== 0 || !preg_match('/"status"\s*:\s*"success"/', $out)) {
        fail("migrations failed (exit $rc): " . substr(trim(strip_tags($out)), 0, 500));
    }
    $v = preg_match('/"version"\s*:\s*"?(\d+)/', $out, $m) ? $m[1] : '?';
    info("migrations at version $v");
}

// Load DXCC entities/prefixes/exceptions (the wizard's last step) when they
// are missing: without them station DXCC can't be chosen and callsigns aren't
// resolved to countries. Wavelog's own cron only refreshes every two months.
// A failed download (e.g. Club Log unreachable) is logged, not fatal, and is
// retried on the next start.
function ensure_dxcc(mysqli $db): void
{
    $prefixes = (int) $db->query('SELECT COUNT(*) FROM dxcc_prefixes')->fetch_row()[0];
    if ($prefixes > 0) {
        return;
    }
    info('loading DXCC data');
    [$rc, $out] = run_wavelog_cli('update', 'dxcc');
    if ($rc !== 0 || !preg_match('/\bsuccess\b/', $out)) {
        info('WARNING: DXCC data not loaded, will retry on next start: ' . substr(trim(strip_tags($out)), 0, 300));
        return;
    }
    $prefixes = (int) $db->query('SELECT COUNT(*) FROM dxcc_prefixes')->fetch_row()[0];
    info("DXCC data loaded ($prefixes prefixes)");
}

// Key values for WL_API_KEYS_JSON entries 0..$count-1, from WL_API_KEY_<n>,
// with surrounding whitespace (e.g. a trailing newline in a Secret) trimmed.
function api_keys_from_env(int $count): array
{
    $keys = [];
    $seen = [];
    for ($n = 0; $n < $count; $n++) {
        $key = trim(env('WL_API_KEY_' . $n));
        if ($key === '') {
            fail("apiKeys[$n]: key is empty");
        }
        if (strlen($key) > 255) {
            fail("apiKeys[$n]: key is longer than 255 characters");
        }
        if (isset($seen[$key])) {
            fail("apiKeys[$n]: same key as apiKeys[{$seen[$key]}]");
        }
        $seen[$key] = $n;
        $keys[] = $key;
    }
    return $keys;
}

// Upsert API keys by key value. Never deletes: keys absent from values stay.
// WL_API_KEYS_JSON is [{description, rights, user}]; the key for entry n is in
// WL_API_KEY_<n>. An empty user means the install admin.
function seed_api_keys(mysqli $db): void
{
    $entries = json_decode(env('WL_API_KEYS_JSON', '[]') ?: '[]', true);
    if (!is_array($entries)) {
        fail('WL_API_KEYS_JSON must be a JSON array');
    }
    $find = $db->prepare('SELECT user_id FROM users WHERE user_name = ?');
    $exists = $db->prepare('SELECT COUNT(*) FROM api WHERE `key` = ?');
    $update = $db->prepare("UPDATE api SET rights = ?, status = 'active', description = ?, user_id = ? WHERE `key` = ?");
    $insert = $db->prepare("INSERT INTO api (`key`, rights, status, description, user_id, created_by) VALUES (?, ?, 'active', ?, ?, ?)");
    $entries = array_values($entries);
    $keys = api_keys_from_env(count($entries));
    foreach ($entries as $n => $entry) {
        $key = $keys[$n];
        $rights = (string) ($entry['rights'] ?? '');
        if ($rights !== 'r' && $rights !== 'rw') {
            fail("apiKeys[$n]: rights must be r or rw");
        }
        $user = (string) ($entry['user'] ?? '');
        if ($user === '') {
            $user = env('WL_ADMIN_USERNAME');
        }
        $find->bind_param('s', $user);
        $find->execute();
        $row = $find->get_result()->fetch_row();
        if (!$row) {
            fail("apiKeys user $user not found");
        }
        $uid = (int) $row[0];
        $desc = (string) ($entry['description'] ?? '');

        $exists->bind_param('s', $key);
        $exists->execute();
        if ((int) $exists->get_result()->fetch_row()[0] > 0) {
            $update->bind_param('ssis', $rights, $desc, $uid, $key);
            $update->execute();
        } else {
            $insert->bind_param('sssii', $key, $rights, $desc, $uid, $uid);
            $insert->execute();
        }
    }
    info('api keys seeded: ' . count($entries));
}

// Link the install admin to an IdP identity so header login lands on it.
// external_account is built exactly as Header_auth::login() builds it, and an
// identity is matched the way User_model::get_by_external_account() matches it.
function link_admin_identity(mysqli $db): void
{
    $iss = env('WL_ADMIN_ISS');
    $sub = env('WL_ADMIN_SUB');
    if ($iss === '' || $sub === '') {
        return;
    }
    $user = env('WL_ADMIN_USERNAME');
    $find = $db->prepare('SELECT user_id FROM users WHERE user_name = ?');
    $find->bind_param('s', $user);
    $find->execute();
    $row = $find->get_result()->fetch_row();
    if (!$row) {
        fail("admin user $user not found");
    }
    $uid = (int) $row[0];
    $taken = $db->prepare("SELECT COUNT(*) FROM users WHERE JSON_VALUE(external_account, '$.iss') = ? AND JSON_VALUE(external_account, '$.sub') = ? AND user_id <> ?");
    $taken->bind_param('ssi', $iss, $sub, $uid);
    $taken->execute();
    if ((int) $taken->get_result()->fetch_row()[0] > 0) {
        fail('SSO identity already linked to another user');
    }
    $account = json_encode(['iss' => $iss, 'sub' => $sub]);
    $update = $db->prepare('UPDATE users SET external_account = ? WHERE user_name = ?');
    $update->bind_param('ss', $account, $user);
    $update->execute();
    info("admin $user linked to SSO identity");
}

function main(): int
{
    // Never print a stack trace: its arguments can include passwords.
    set_exception_handler(function (Throwable $e): void {
        fail('unexpected error: ' . $e->getMessage());
    });

    render_config();
    if (env('WL_AUTH_MODE', 'local') === 'header') {
        render_sso();
    }
    info('config rendered');

    $db = wait_for_db();
    $state = install_state($db);
    info("database state: $state");
    if ($state === 'partial') {
        fail('partial install detected; restore from backup or drop the schema');
    }
    if ($state === 'empty') {
        install_schema();
        if (install_state($db) !== 'installed') {
            fail('schema install did not create the admin user');
        }
        info('schema installed');
    }
    $db->close();

    run_migrations();

    // Migrations may add columns (api.created_by, users.external_account), so
    // seed on a fresh connection.
    $db = db();
    seed_api_keys($db);
    link_admin_identity($db);
    ensure_dxcc($db);
    $db->close();
    return 0;
}

// Tests define WL_BOOTSTRAP_NO_MAIN to include the functions without running.
if (!defined('WL_BOOTSTRAP_NO_MAIN')) {
    exit(main());
}
