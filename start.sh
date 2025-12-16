#!/usr/bin/env bash
set -euo pipefail

# === config ===
MINECRAFT_VERSION="${MINECRAFT_VERSION:-1.21.11}"
FABRIC_LOADER_VERSION="${FABRIC_LOADER_VERSION:-0.18.2}"
FABRIC_INSTALLER_VERSION="${FABRIC_INSTALLER_VERSION:-1.1.0}"
FABRIC_API_VERSION="${FABRIC_API_VERSION:-0.139.5+1.21.11}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="$SCRIPT_DIR/.cache"
DATA_DIR="$SCRIPT_DIR/data"
CONFIG_DIR="$SCRIPT_DIR/config"
PLUGINS_SRC_DIR="$SCRIPT_DIR/plugins"
DOCKER_DIR="$SCRIPT_DIR/docker"

# flags
FORCE_BUILD=false
BUILD_ONLY=false
PRESERVE_WORLDS=false
CLEANUP_CACHE=true

# === colors ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# === parse args ===
for arg in "$@"; do
    case $arg in
        --build) FORCE_BUILD=true ;;
        --build-only) BUILD_ONLY=true; FORCE_BUILD=true ;;
        --preserve-worlds) PRESERVE_WORLDS=true ;;
        --no-cleanup) CLEANUP_CACHE=false ;;
        --mc-version=*) MINECRAFT_VERSION="${arg#*=}" ;;
        --loader-version=*) FABRIC_LOADER_VERSION="${arg#*=}" ;;
        --help|-h)
            echo "usage: start.sh [options]"
            echo ""
            echo "options:"
            echo "  --build               force rebuild before starting"
            echo "  --build-only          build without starting"
            echo "  --preserve-worlds     keep world data during rebuild"
            echo "  --no-cleanup          keep intermediate build files in cache"
            echo "  --mc-version=X.X.X    minecraft version (default: $MINECRAFT_VERSION)"
            echo "  --loader-version=X.X  fabric loader version (default: $FABRIC_LOADER_VERSION)"
            echo ""
            echo "if data/ is missing or outdated, build runs automatically"
            exit 0
            ;;
    esac
done

# === prerequisite check ===
check_docker() {
    if ! command -v docker &> /dev/null; then
        log_error "docker not found. install docker first."
        exit 1
    fi
    
    if ! docker info &> /dev/null; then
        log_error "docker daemon not running. start docker first."
        exit 1
    fi
    
    log_ok "docker available"
}

# === build detection ===
needs_build() {
    [[ ! -d "$DATA_DIR" ]] && return 0
    [[ ! -f "$DATA_DIR/server.jar" ]] && return 0

    if [[ -d "$PLUGINS_SRC_DIR" ]]; then
        newest_src=$(find "$PLUGINS_SRC_DIR" -name "*.java" -newer "$DATA_DIR/server.jar" 2>/dev/null | head -n1)
        [[ -n "$newest_src" ]] && return 0
    fi

    if [[ -d "$CONFIG_DIR" ]]; then
        newest_cfg=$(find "$CONFIG_DIR" -type f -newer "$DATA_DIR/server.jar" 2>/dev/null | head -n1)
        [[ -n "$newest_cfg" ]] && return 0
    fi

    return 1
}

# === scaffold docker files ===
scaffold_docker() {
    log_info "scaffolding docker environment..."

    mkdir -p "$DOCKER_DIR"

    # builder dockerfile - for gradle mod compilation
    if [[ ! -f "$DOCKER_DIR/Dockerfile.builder" ]]; then
        cat > "$DOCKER_DIR/Dockerfile.builder" << 'EOF'
FROM eclipse-temurin:21-jdk

RUN apt-get update && apt-get install -y \
    git \
    curl \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# install gradle (9.2.1 required by fabric-loom 1.14)
ENV GRADLE_VERSION=9.2.1
RUN curl -fsSL "https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip" -o gradle.zip \
    && unzip -q gradle.zip -d /opt \
    && rm gradle.zip \
    && ln -s /opt/gradle-${GRADLE_VERSION}/bin/gradle /usr/local/bin/gradle

WORKDIR /build
EOF
        log_ok "created Dockerfile.builder"
    fi

    # server dockerfile
    if [[ ! -f "$DOCKER_DIR/Dockerfile.server" ]]; then
        cat > "$DOCKER_DIR/Dockerfile.server" << 'EOF'
FROM eclipse-temurin:21-jre

WORKDIR /server

EXPOSE 25565

# default memory settings (override via env)
ENV JAVA_OPTS="-Xms1G -Xmx2G"

ENTRYPOINT ["sh", "-c", "java $JAVA_OPTS -jar server.jar nogui"]
EOF
        log_ok "created Dockerfile.server"
    fi
    
    # docker-compose
    if [[ ! -f "$DOCKER_DIR/docker-compose.yml" ]]; then
        cat > "$DOCKER_DIR/docker-compose.yml" << 'EOF'
services:
  minecraft:
    build:
      context: .
      dockerfile: Dockerfile.server
    container_name: minecraft-server
    stdin_open: true
    tty: true
    ports:
      - "25565:25565"      # java edition
      - "19132:19132/udp"  # bedrock edition (geyser)
    volumes:
      - ../data:/server
    environment:
      - JAVA_OPTS=${JAVA_OPTS:--Xms1G -Xmx2G}
      - DATABASE_URL=jdbc:postgresql://postgres:5432/minecraft
      - DATABASE_USER=minecraft
      - DATABASE_PASSWORD=minecraft
      - REDIS_HOST=redis
      - REDIS_PORT=6379
    depends_on:
      - postgres
      - redis
    restart: unless-stopped

  postgres:
    image: postgres:16-alpine
    container_name: minecraft-postgres
    environment:
      POSTGRES_DB: minecraft
      POSTGRES_USER: minecraft
      POSTGRES_PASSWORD: minecraft
    volumes:
      - postgres_data:/var/lib/postgresql/data
      - ../services/database/init.sql:/docker-entrypoint-initdb.d/init.sql:ro
    restart: unless-stopped

  redis:
    image: redis:7-alpine
    container_name: minecraft-redis
    command: redis-server --appendonly yes
    volumes:
      - redis_data:/data
    restart: unless-stopped

  playit:
    image: ghcr.io/playit-cloud/playit-agent:0.16
    container_name: minecraft-playit
    network_mode: host
    environment:
      - SECRET_KEY=
    restart: unless-stopped

  xbox-broadcast:
    image: ghcr.io/mcxboxbroadcast/standalone:latest
    container_name: xbox-broadcast
    volumes:
      - ./xbox-broadcast:/opt/app/config
    depends_on:
      - minecraft
    restart: unless-stopped
    stdin_open: true
    tty: true

volumes:
  postgres_data:
  redis_data:
EOF
        log_ok "created docker-compose.yml"
    fi
    
    log_ok "docker environment ready"
}

# === scaffold directories ===
scaffold_dirs() {
    log_info "scaffolding directories..."
    mkdir -p "$CACHE_DIR"
    mkdir -p "$CONFIG_DIR"/{server,access,mods,worlds}
    mkdir -p "$PLUGINS_SRC_DIR"
    mkdir -p "$SCRIPT_DIR/shared"/{types,config,util}
    mkdir -p "$SCRIPT_DIR/services"/{database,redis,backups}
    mkdir -p "$SCRIPT_DIR/env"
    mkdir -p "$SCRIPT_DIR/tooling"
    log_ok "directories ready"
}

# === scaffold services (postgres, redis, backups) ===
scaffold_services() {
    log_info "scaffolding services..."
    
    SERVICES_DIR="$SCRIPT_DIR/services"
    
    # database init script
    if [[ ! -f "$SERVICES_DIR/database/init.sql" ]]; then
        cat > "$SERVICES_DIR/database/init.sql" << 'EOF'
-- minecraft server database schema

-- player data
CREATE TABLE IF NOT EXISTS players (
    uuid UUID PRIMARY KEY,
    username VARCHAR(16) NOT NULL,
    first_join TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    last_seen TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    play_time_seconds BIGINT DEFAULT 0,
    data JSONB DEFAULT '{}'
);

CREATE INDEX IF NOT EXISTS idx_players_username ON players(username);

-- player stats
CREATE TABLE IF NOT EXISTS player_stats (
    uuid UUID REFERENCES players(uuid) ON DELETE CASCADE,
    stat_key VARCHAR(64) NOT NULL,
    stat_value BIGINT DEFAULT 0,
    PRIMARY KEY (uuid, stat_key)
);

-- economy (optional)
CREATE TABLE IF NOT EXISTS economy (
    uuid UUID PRIMARY KEY REFERENCES players(uuid) ON DELETE CASCADE,
    balance DECIMAL(20, 2) DEFAULT 0.00
);

-- audit log
CREATE TABLE IF NOT EXISTS audit_log (
    id SERIAL PRIMARY KEY,
    timestamp TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    actor_uuid UUID,
    action VARCHAR(64) NOT NULL,
    target_uuid UUID,
    details JSONB DEFAULT '{}'
);

CREATE INDEX IF NOT EXISTS idx_audit_timestamp ON audit_log(timestamp);
EOF
        log_ok "created database/init.sql"
    fi
    
    # DatabaseService.java
    if [[ ! -f "$SERVICES_DIR/database/DatabaseService.java" ]]; then
        cat > "$SERVICES_DIR/database/DatabaseService.java" << 'EOF'
package com.server.services.database;

import com.zaxxer.hikari.HikariConfig;
import com.zaxxer.hikari.HikariDataSource;

import java.sql.Connection;
import java.sql.SQLException;

/**
 * database connection pool using hikaricp.
 * configure via environment variables or direct setters.
 */
public class DatabaseService {
    
    private static DatabaseService instance;
    private HikariDataSource dataSource;
    
    private String jdbcUrl;
    private String username;
    private String password;
    
    private DatabaseService() {
        // read from env by default
        this.jdbcUrl = System.getenv("DATABASE_URL");
        this.username = System.getenv("DATABASE_USER");
        this.password = System.getenv("DATABASE_PASSWORD");
    }
    
    public static synchronized DatabaseService getInstance() {
        if (instance == null) {
            instance = new DatabaseService();
        }
        return instance;
    }
    
    public DatabaseService jdbcUrl(String url) {
        this.jdbcUrl = url;
        return this;
    }
    
    public DatabaseService credentials(String user, String pass) {
        this.username = user;
        this.password = pass;
        return this;
    }
    
    public void connect() {
        if (dataSource != null) return;
        
        HikariConfig config = new HikariConfig();
        config.setJdbcUrl(jdbcUrl);
        config.setUsername(username);
        config.setPassword(password);
        
        // pool settings
        config.setMaximumPoolSize(10);
        config.setMinimumIdle(2);
        config.setIdleTimeout(300000);
        config.setConnectionTimeout(10000);
        config.setMaxLifetime(600000);
        
        // postgres optimizations
        config.addDataSourceProperty("cachePrepStmts", "true");
        config.addDataSourceProperty("prepStmtCacheSize", "250");
        config.addDataSourceProperty("prepStmtCacheSqlLimit", "2048");
        
        dataSource = new HikariDataSource(config);
    }
    
    public Connection getConnection() throws SQLException {
        if (dataSource == null) {
            throw new IllegalStateException("database not connected. call connect() first.");
        }
        return dataSource.getConnection();
    }
    
    public void shutdown() {
        if (dataSource != null) {
            dataSource.close();
            dataSource = null;
        }
    }
    
    public boolean isConnected() {
        return dataSource != null && !dataSource.isClosed();
    }
}
EOF
        log_ok "created database/DatabaseService.java"
    fi
    
    # RedisService.java
    if [[ ! -f "$SERVICES_DIR/redis/RedisService.java" ]]; then
        cat > "$SERVICES_DIR/redis/RedisService.java" << 'EOF'
package com.server.services.redis;

import redis.clients.jedis.Jedis;
import redis.clients.jedis.JedisPool;
import redis.clients.jedis.JedisPoolConfig;

import java.time.Duration;
import java.util.function.Function;

/**
 * redis connection pool using jedis.
 * configure via environment variables or direct setters.
 */
public class RedisService {
    
    private static RedisService instance;
    private JedisPool pool;
    
    private String host;
    private int port;
    
    private RedisService() {
        // read from env by default
        this.host = System.getenv().getOrDefault("REDIS_HOST", "localhost");
        this.port = Integer.parseInt(System.getenv().getOrDefault("REDIS_PORT", "6379"));
    }
    
    public static synchronized RedisService getInstance() {
        if (instance == null) {
            instance = new RedisService();
        }
        return instance;
    }
    
    public RedisService host(String host) {
        this.host = host;
        return this;
    }
    
    public RedisService port(int port) {
        this.port = port;
        return this;
    }
    
    public void connect() {
        if (pool != null) return;
        
        JedisPoolConfig config = new JedisPoolConfig();
        config.setMaxTotal(16);
        config.setMaxIdle(8);
        config.setMinIdle(2);
        config.setMaxWait(Duration.ofSeconds(10));
        config.setTestOnBorrow(true);
        
        pool = new JedisPool(config, host, port);
    }
    
    /**
     * execute a redis command with automatic resource management.
     */
    public <T> T execute(Function<Jedis, T> command) {
        if (pool == null) {
            throw new IllegalStateException("redis not connected. call connect() first.");
        }
        try (Jedis jedis = pool.getResource()) {
            return command.apply(jedis);
        }
    }
    
    /**
     * execute a redis command that returns void.
     */
    public void run(java.util.function.Consumer<Jedis> command) {
        execute(jedis -> {
            command.accept(jedis);
            return null;
        });
    }
    
    // convenience methods
    
    public String get(String key) {
        return execute(j -> j.get(key));
    }
    
    public void set(String key, String value) {
        run(j -> j.set(key, value));
    }
    
    public void setex(String key, long seconds, String value) {
        run(j -> j.setex(key, seconds, value));
    }
    
    public void del(String... keys) {
        run(j -> j.del(keys));
    }
    
    public boolean exists(String key) {
        return execute(j -> j.exists(key));
    }
    
    public void publish(String channel, String message) {
        run(j -> j.publish(channel, message));
    }
    
    public void shutdown() {
        if (pool != null) {
            pool.close();
            pool = null;
        }
    }
    
    public boolean isConnected() {
        return pool != null && !pool.isClosed();
    }
}
EOF
        log_ok "created redis/RedisService.java"
    fi
    
    # backup config
    if [[ ! -f "$SERVICES_DIR/backups/config.yml" ]]; then
        cat > "$SERVICES_DIR/backups/config.yml" << 'EOF'
# backup configuration

enabled: true

# backup schedule (cron format)
# default: every 6 hours
schedule: "0 */6 * * *"

# what to backup
targets:
  worlds: true
  plugins: true
  configs: true
  database: true

# retention policy
retention:
  # how many backups to keep
  max_backups: 10
  # delete backups older than this (days)
  max_age_days: 30

# backup storage
storage:
  # local, s3, or both
  type: local
  
  local:
    path: ./backups
    
  s3:
    enabled: false
    bucket: ""
    region: ""
    prefix: "minecraft-backups/"
    # credentials from env: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY

# compression
compression:
  enabled: true
  # gzip, zstd
  format: gzip
  level: 6

# notifications
notifications:
  enabled: false
  # discord webhook for backup status
  discord_webhook: ""
  # only notify on failure
  on_failure_only: true
EOF
        log_ok "created backups/config.yml"
    fi
    
    log_ok "services ready"
}

# === download fabric server ===
download_fabric() {
    FABRIC_JAR="$CACHE_DIR/fabric-server-$MINECRAFT_VERSION-$FABRIC_LOADER_VERSION.jar"

    if [[ -f "$FABRIC_JAR" ]]; then
        log_ok "fabric server $MINECRAFT_VERSION (loader $FABRIC_LOADER_VERSION) cached"
        return
    fi

    log_info "downloading fabric server $MINECRAFT_VERSION (loader $FABRIC_LOADER_VERSION)..."

    local url="https://meta.fabricmc.net/v2/versions/loader/$MINECRAFT_VERSION/$FABRIC_LOADER_VERSION/$FABRIC_INSTALLER_VERSION/server/jar"

    if curl -fsSL "$url" -o "$FABRIC_JAR"; then
        log_ok "fabric server downloaded"
    else
        log_error "failed to download fabric server"
        exit 1
    fi
}

# === seed configs ===
seed_configs() {
    log_info "seeding configs..."
    
    seed_if_missing() {
        local target="$1"
        local content="$2"
        [[ ! -f "$target" ]] && echo "$content" > "$target"
    }
    
    seed_file() {
        local target="$1"
        [[ -f "$target" ]] && return
        mkdir -p "$(dirname "$target")"
        cat > "$target"
    }
    
    # server.properties
    seed_file "$CONFIG_DIR/server/server.properties" << 'EOF'
# server basics
server-port=25565
max-players=16
motd=A Minecraft Server
white-list=false
enforce-whitelist=false
online-mode=false
enforce-secure-profile=false

# performance - tuned for 16 players
view-distance=10
simulation-distance=8
network-compression-threshold=256
max-chained-neighbor-updates=1000000

# gameplay
difficulty=normal
gamemode=survival
pvp=true
allow-flight=true
spawn-protection=0
enable-command-block=false

# world settings
level-name=world
level-seed=
level-type=minecraft\:normal
generate-structures=true
max-world-size=29999984
spawn-npcs=true
spawn-animals=true
spawn-monsters=true

# misc
enable-status=true
enable-query=false
enable-rcon=false
sync-chunk-writes=true
EOF

    seed_if_missing "$CONFIG_DIR/access/ops.json" "[]"
    seed_if_missing "$CONFIG_DIR/access/whitelist.json" "[]"
    seed_if_missing "$CONFIG_DIR/access/banned-players.json" "[]"
    seed_if_missing "$CONFIG_DIR/access/banned-ips.json" "[]"
    seed_if_missing "$SCRIPT_DIR/env/dev.env" "# development environment
JAVA_OPTS=\"-Xms1G -Xmx2G\"
"
    seed_if_missing "$SCRIPT_DIR/env/prod.env" "# production environment
JAVA_OPTS=\"-Xms4G -Xmx8G\"
"

    # geyser config (bedrock support)
    mkdir -p "$CONFIG_DIR/mods/Geyser-Fabric"
    seed_file "$CONFIG_DIR/mods/Geyser-Fabric/config.yml" << 'EOF'
# geyser configuration - bedrock support
bedrock:
  address: 0.0.0.0
  port: 19132
  clone-remote-port: false

java:
  auth-type: floodgate

motd:
  primary-motd: A Minecraft Server
  secondary-motd: ""
  passthrough-motd: true
  max-players: 16
  passthrough-player-counts: true
  integrated-ping-passthrough: true
  ping-passthrough-interval: 3

gameplay:
  server-name: A Minecraft Server
  show-cooldown: title
  command-suggestions: true
  show-coordinates: true
  disable-bedrock-scaffolding: false
  nether-roof-workaround: false
  emotes-enabled: true
  unusable-space-block: minecraft:barrier
  enable-custom-content: true
  force-resource-packs: true
  enable-integrated-pack: true
  forward-player-ping: false
  xbox-achievements-enabled: false
  max-visible-custom-skulls: 128
  custom-skull-render-distance: 32

default-locale: system
log-player-ip-addresses: false
saved-user-logins: []
pending-authentication-timeout: 120
notify-on-new-bedrock-update: false

advanced:
  cache-images: 7
  scoreboard-packet-threshold: 20
  add-team-suggestions: true
  resource-pack-urls: []
  floodgate-key-file: key.pem

  java:
    use-haproxy-protocol: false
    use-direct-connection: true
    disable-compression: true

  bedrock:
    broadcast-port: 0
    compression-level: 6
    use-haproxy-protocol: false
    haproxy-protocol-whitelisted-ips: []
    mtu: 1400
    validate-bedrock-login: true

debug-mode: false
config-version: 5
EOF

    # floodgate config (bedrock auth)
    mkdir -p "$CONFIG_DIR/mods/floodgate"
    seed_file "$CONFIG_DIR/mods/floodgate/config.yml" << 'EOF'
# floodgate configuration - bedrock authentication
key-file-name: key.pem

# no prefix for bedrock usernames (cleaner names)
username-prefix: ""
replace-spaces: true

disconnect:
  invalid-key: Unable to verify your connection. Please try again.
  invalid-arguments-length: Connection error. Please restart your game and try again.

player-link:
  enabled: false
  require-link: false
  enable-own-linking: false
  allowed: false
  link-code-timeout: 300
  type: sqlite
  enable-global-linking: false

metrics:
  enabled: false
  uuid: 00000000-0000-0000-0000-000000000000

config-version: 3
EOF

    log_ok "configs ready"
}

# === scaffold example mods ===
scaffold_example_mods() {
    # --- server-only mod ---
    SERVER_MOD_DIR="$PLUGINS_SRC_DIR/example-server"

    if [[ ! -d "$SERVER_MOD_DIR/src" ]]; then
        log_info "scaffolding example-server mod..."

        mkdir -p "$SERVER_MOD_DIR/src/main/java/com/example/server"
        mkdir -p "$SERVER_MOD_DIR/src/main/resources"

        cat > "$SERVER_MOD_DIR/src/main/resources/fabric.mod.json" << 'EOF'
{
    "schemaVersion": 1,
    "id": "example-server",
    "version": "1.0.0",
    "name": "Example Server Mod",
    "description": "A server-side only example mod",
    "authors": ["Server Admin"],
    "contact": {},
    "license": "MIT",
    "environment": "server",
    "entrypoints": {
        "server": ["com.example.server.ExampleServerMod"]
    },
    "depends": {
        "fabricloader": ">=0.15.0",
        "minecraft": ">=1.21",
        "java": ">=21",
        "fabric-api": "*"
    }
}
EOF

        cat > "$SERVER_MOD_DIR/src/main/java/com/example/server/ExampleServerMod.java" << 'EOF'
package com.example.server;

import net.fabricmc.api.DedicatedServerModInitializer;
import net.fabricmc.fabric.api.command.v2.CommandRegistrationCallback;
import net.minecraft.commands.Commands;
import net.minecraft.network.chat.Component;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * Example server-side only mod.
 * This mod only runs on the server and adds a simple /hello command.
 */
public class ExampleServerMod implements DedicatedServerModInitializer {

    public static final String MOD_ID = "example-server";
    public static final Logger LOGGER = LoggerFactory.getLogger(MOD_ID);

    @Override
    public void onInitializeServer() {
        LOGGER.info("Example server mod initialized!");

        // register a simple /hello command
        CommandRegistrationCallback.EVENT.register((dispatcher, registryAccess, environment) -> {
            dispatcher.register(Commands.literal("hello")
                .executes(context -> {
                    context.getSource().sendSuccess(
                        () -> Component.literal("Hello from the example server mod!"),
                        false
                    );
                    return 1;
                })
            );
        });
    }
}
EOF

        cat > "$SERVER_MOD_DIR/build.gradle" << 'EOF'
plugins {
    id 'fabric-loom' version '1.14.6'
    id 'java'
}

version = '1.0.0'
group = 'com.example'

repositories {
    mavenCentral()
}

loom {
    serverOnlyMinecraftJar()
}

dependencies {
    minecraft "com.mojang:minecraft:${project.minecraft_version}"
    mappings loom.officialMojangMappings()
    modImplementation "net.fabricmc:fabric-loader:${project.loader_version}"
    modImplementation "net.fabricmc.fabric-api:fabric-api:${project.fabric_version}"
}

java {
    sourceCompatibility = JavaVersion.VERSION_21
    targetCompatibility = JavaVersion.VERSION_21
}

tasks.withType(JavaCompile).configureEach {
    options.encoding = 'UTF-8'
}
EOF

        cat > "$SERVER_MOD_DIR/settings.gradle" << 'EOF'
pluginManagement {
    repositories {
        maven { url = 'https://maven.fabricmc.net/' }
        gradlePluginPortal()
    }
}
rootProject.name = 'example-server'
EOF

        cat > "$SERVER_MOD_DIR/gradle.properties" << EOF
org.gradle.jvmargs=-Xmx1G
minecraft_version=$MINECRAFT_VERSION
loader_version=$FABRIC_LOADER_VERSION
fabric_version=$FABRIC_API_VERSION
EOF

        log_ok "example-server mod scaffolded"
    fi

    # --- server+client compatible mod ---
    SHARED_MOD_DIR="$PLUGINS_SRC_DIR/example-shared"

    if [[ ! -d "$SHARED_MOD_DIR/src" ]]; then
        log_info "scaffolding example-shared mod..."

        mkdir -p "$SHARED_MOD_DIR/src/main/java/com/example/shared"
        mkdir -p "$SHARED_MOD_DIR/src/main/resources"

        cat > "$SHARED_MOD_DIR/src/main/resources/fabric.mod.json" << 'EOF'
{
    "schemaVersion": 1,
    "id": "example-shared",
    "version": "1.0.0",
    "name": "Example Shared Mod",
    "description": "A server+client compatible example mod",
    "authors": ["Server Admin"],
    "contact": {},
    "license": "MIT",
    "environment": "*",
    "entrypoints": {
        "main": ["com.example.shared.ExampleSharedMod"],
        "client": ["com.example.shared.ExampleSharedModClient"],
        "server": ["com.example.shared.ExampleSharedModServer"]
    },
    "depends": {
        "fabricloader": ">=0.15.0",
        "minecraft": ">=1.21",
        "java": ">=21",
        "fabric-api": "*"
    }
}
EOF

        cat > "$SHARED_MOD_DIR/src/main/java/com/example/shared/ExampleSharedMod.java" << 'EOF'
package com.example.shared;

import net.fabricmc.api.ModInitializer;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * Example shared mod - main entrypoint.
 * This code runs on both client and server.
 */
public class ExampleSharedMod implements ModInitializer {

    public static final String MOD_ID = "example-shared";
    public static final Logger LOGGER = LoggerFactory.getLogger(MOD_ID);

    @Override
    public void onInitialize() {
        LOGGER.info("Example shared mod initialized (common)!");

        // register things that work on both client and server here
        // e.g., custom items, blocks, recipes, etc.
    }
}
EOF

        cat > "$SHARED_MOD_DIR/src/main/java/com/example/shared/ExampleSharedModClient.java" << 'EOF'
package com.example.shared;

import net.fabricmc.api.ClientModInitializer;
import net.fabricmc.api.EnvType;
import net.fabricmc.api.Environment;

/**
 * Example shared mod - client entrypoint.
 * This code only runs on the client.
 */
@Environment(EnvType.CLIENT)
public class ExampleSharedModClient implements ClientModInitializer {

    @Override
    public void onInitializeClient() {
        ExampleSharedMod.LOGGER.info("Example shared mod initialized (client)!");

        // register client-only things here
        // e.g., keybindings, renderers, HUD elements, etc.
    }
}
EOF

        cat > "$SHARED_MOD_DIR/src/main/java/com/example/shared/ExampleSharedModServer.java" << 'EOF'
package com.example.shared;

import net.fabricmc.api.DedicatedServerModInitializer;
import net.fabricmc.api.EnvType;
import net.fabricmc.api.Environment;
import net.fabricmc.fabric.api.command.v2.CommandRegistrationCallback;
import net.minecraft.commands.Commands;
import net.minecraft.network.chat.Component;

/**
 * Example shared mod - server entrypoint.
 * This code only runs on the dedicated server.
 */
@Environment(EnvType.SERVER)
public class ExampleSharedModServer implements DedicatedServerModInitializer {

    @Override
    public void onInitializeServer() {
        ExampleSharedMod.LOGGER.info("Example shared mod initialized (server)!");

        // register server-only things here
        // e.g., commands, server tick handlers, etc.

        CommandRegistrationCallback.EVENT.register((dispatcher, registryAccess, environment) -> {
            dispatcher.register(Commands.literal("shared")
                .executes(context -> {
                    context.getSource().sendSuccess(
                        () -> Component.literal("Hello from the example shared mod!"),
                        false
                    );
                    return 1;
                })
            );
        });
    }
}
EOF

        cat > "$SHARED_MOD_DIR/build.gradle" << 'EOF'
plugins {
    id 'fabric-loom' version '1.14.6'
    id 'java'
}

version = '1.0.0'
group = 'com.example'

repositories {
    mavenCentral()
}

dependencies {
    minecraft "com.mojang:minecraft:${project.minecraft_version}"
    mappings loom.officialMojangMappings()
    modImplementation "net.fabricmc:fabric-loader:${project.loader_version}"
    modImplementation "net.fabricmc.fabric-api:fabric-api:${project.fabric_version}"
}

java {
    sourceCompatibility = JavaVersion.VERSION_21
    targetCompatibility = JavaVersion.VERSION_21
}

tasks.withType(JavaCompile).configureEach {
    options.encoding = 'UTF-8'
}
EOF

        cat > "$SHARED_MOD_DIR/settings.gradle" << 'EOF'
pluginManagement {
    repositories {
        maven { url = 'https://maven.fabricmc.net/' }
        gradlePluginPortal()
    }
}
rootProject.name = 'example-shared'
EOF

        cat > "$SHARED_MOD_DIR/gradle.properties" << EOF
org.gradle.jvmargs=-Xmx1G
minecraft_version=$MINECRAFT_VERSION
loader_version=$FABRIC_LOADER_VERSION
fabric_version=$FABRIC_API_VERSION
EOF

        log_ok "example-shared mod scaffolded"
    fi
}

# === compile custom mods ===
compile_mods() {
    log_info "compiling custom mods..."

    # build the builder image if needed
    docker build -q -t fabric-builder -f "$DOCKER_DIR/Dockerfile.builder" "$DOCKER_DIR" > /dev/null

    # gradle flags: use --info for verbose, --quiet for silent
    local gradle_flags="--stacktrace"
    [[ "${VERBOSE:-false}" == "true" ]] && gradle_flags="--info --stacktrace"

    for mod_dir in "$PLUGINS_SRC_DIR"/*/; do
        if [[ -d "$mod_dir" ]] && [[ -f "$mod_dir/build.gradle" ]]; then
            mod_name=$(basename "$mod_dir")
            log_info "building $mod_name..."

            # use gradle wrapper if available, otherwise use system gradle
            if [[ -f "$mod_dir/gradlew" ]]; then
                docker run --rm \
                    -v "$mod_dir:/build" \
                    -w /build \
                    fabric-builder \
                    ./gradlew build $gradle_flags
            else
                docker run --rm \
                    -v "$mod_dir:/build" \
                    -w /build \
                    fabric-builder \
                    gradle build $gradle_flags
            fi

            log_ok "$mod_name built"
        fi
    done
}

# === download mods ===
download_mods() {
    log_info "downloading mods..."

    MODS_DIR="$CACHE_DIR/mods"
    mkdir -p "$MODS_DIR"

    download_mod() {
        local url="$1"
        local name="$2"
        local target="$MODS_DIR/$name"

        if [[ -f "$target" ]]; then
            return
        fi

        log_info "downloading $name..."
        if curl -fsSL "$url" -o "$target"; then
            log_ok "$name downloaded"
        else
            log_warn "failed to download $name"
        fi
    }

    # fabric api (required by most mods)
    download_mod \
        "https://cdn.modrinth.com/data/P7dR8mSH/versions/KhCFoeip/fabric-api-0.139.5%2B1.21.11.jar" \
        "fabric-api.jar"

    # geyser stack - bedrock crossplay
    download_mod \
        "https://download.geysermc.org/v2/projects/geyser/versions/latest/builds/latest/downloads/fabric" \
        "Geyser-Fabric.jar"
    download_mod \
        "https://cdn.modrinth.com/data/bWrNNfkb/versions/wzwExuYr/Floodgate-Fabric-2.2.6-b54.jar" \
        "Floodgate-Fabric.jar"

    # viaversion - multi-version support
    download_mod \
        "https://cdn.modrinth.com/data/P1OZGk5p/versions/wJ7j2lM6/ViaVersion-5.6.0.jar" \
        "ViaVersion.jar"
    download_mod \
        "https://cdn.modrinth.com/data/NpvuJQoq/versions/DaWDWSK8/ViaBackwards-5.6.0.jar" \
        "ViaBackwards.jar"
    download_mod \
        "https://cdn.modrinth.com/data/YlKdE5VK/versions/jmsoyTm9/ViaFabric-0.4.21%2B129-main.jar" \
        "ViaFabric.jar"

    # axiom - building tool
    download_mod \
        "https://cdn.modrinth.com/data/N6n5dqoA/versions/M0Jr2ivY/Axiom-5.2.1-for-MC1.21.11.jar" \
        "Axiom.jar"

    # simple voice chat
    download_mod \
        "https://cdn.modrinth.com/data/9eGKb6K1/versions/K5zIeqNd/voicechat-fabric-1.21.11-2.6.7.jar" \
        "voicechat.jar"

    # lithium - performance optimization
    download_mod \
        "https://cdn.modrinth.com/data/gvQqBUqZ/versions/4DdLmtyz/lithium-fabric-0.21.1%2Bmc1.21.11.jar" \
        "lithium.jar"

    # distant horizons - LOD rendering
    download_mod \
        "https://cdn.modrinth.com/data/uCdwusMi/versions/MEUmB9jk/DistantHorizons-2.4.2-b-1.21.11-fabric-neoforge.jar" \
        "distant-horizons.jar"

    log_ok "mods ready"
}

# === download playit agent ===
download_playit() {
    log_info "checking playit.gg agent..."
    
    PLAYIT_DIR="$SCRIPT_DIR/tools"
    PLAYIT_BIN="$PLAYIT_DIR/playit"
    
    mkdir -p "$PLAYIT_DIR"
    
    if [[ -f "$PLAYIT_BIN" ]]; then
        log_ok "playit agent cached"
        return
    fi
    
    # detect architecture
    local arch
    arch=$(uname -m)
    local url=""
    
    case "$arch" in
        x86_64|amd64)
            url="https://github.com/playit-cloud/playit-agent/releases/download/v0.16.5/playit-linux-amd64"
            ;;
        i686|i386)
            url="https://github.com/playit-cloud/playit-agent/releases/download/v0.16.5/playit-linux-i686"
            ;;
        armv7l)
            url="https://github.com/playit-cloud/playit-agent/releases/download/v0.16.5/playit-linux-armv7"
            ;;
        aarch64|arm64)
            url="https://github.com/playit-cloud/playit-agent/releases/download/v0.16.5/playit-linux-aarch64"
            ;;
        *)
            log_warn "unsupported architecture for playit: $arch"
            return
            ;;
    esac
    
    log_info "downloading playit agent for $arch..."
    if curl -fsSL "$url" -o "$PLAYIT_BIN"; then
        chmod +x "$PLAYIT_BIN"
        log_ok "playit agent downloaded"
    else
        log_warn "failed to download playit agent"
    fi
}

# === assemble data/ ===
assemble_data() {
    log_info "assembling data/..."

    FABRIC_JAR="$CACHE_DIR/fabric-server-$MINECRAFT_VERSION-$FABRIC_LOADER_VERSION.jar"
    MODS_DIR="$CACHE_DIR/mods"

    # preserve worlds if requested
    if [[ "$PRESERVE_WORLDS" == true ]] && [[ -d "$DATA_DIR" ]]; then
        mkdir -p "$CACHE_DIR/worlds_backup"
        for world in world world_nether world_the_end; do
            [[ -d "$DATA_DIR/$world" ]] && mv "$DATA_DIR/$world" "$CACHE_DIR/worlds_backup/"
        done
    fi

    rm -rf "$DATA_DIR"
    mkdir -p "$DATA_DIR/mods"
    mkdir -p "$DATA_DIR/config"

    # restore worlds
    if [[ "$PRESERVE_WORLDS" == true ]] && [[ -d "$CACHE_DIR/worlds_backup" ]]; then
        for world in "$CACHE_DIR/worlds_backup"/*/; do
            [[ -d "$world" ]] && mv "$world" "$DATA_DIR/"
        done
        rm -rf "$CACHE_DIR/worlds_backup"
    fi

    cp "$FABRIC_JAR" "$DATA_DIR/server.jar"
    echo "eula=true" > "$DATA_DIR/eula.txt"
    cp "$CONFIG_DIR/server/"* "$DATA_DIR/" 2>/dev/null || true
    cp "$CONFIG_DIR/access/"* "$DATA_DIR/" 2>/dev/null || true

    # copy mod config directories (geyser, floodgate, etc.)
    for mod_config_dir in "$CONFIG_DIR/mods"/*/; do
        if [[ -d "$mod_config_dir" ]]; then
            mod_name=$(basename "$mod_config_dir")
            mkdir -p "$DATA_DIR/config/$mod_name"
            cp -r "$mod_config_dir"/* "$DATA_DIR/config/$mod_name/" 2>/dev/null || true
        fi
    done

    # copy downloaded mods
    if [[ -d "$MODS_DIR" ]]; then
        cp "$MODS_DIR"/*.jar "$DATA_DIR/mods/" 2>/dev/null || true
    fi

    # copy compiled custom mods from plugins/
    for mod_dir in "$PLUGINS_SRC_DIR"/*/; do
        if [[ -d "$mod_dir" ]]; then
            mod_name=$(basename "$mod_dir")
            # fabric-loom outputs to build/libs/
            jar_file=$(find "$mod_dir/build/libs" -name "*.jar" ! -name "*-sources.jar" ! -name "*-dev.jar" 2>/dev/null | head -n1)
            if [[ -n "$jar_file" ]]; then
                cp "$jar_file" "$DATA_DIR/mods/"
                log_info "copied $mod_name mod"
            fi
        fi
    done

    log_ok "data/ assembled"
}

# === cleanup cache ===
cleanup_cache() {
    log_info "cleaning up cache..."
    
    # try without sudo first, fall back to sudo if needed
    if rm -rf "$CACHE_DIR" 2>/dev/null; then
        log_ok "cache cleaned"
    elif sudo rm -rf "$CACHE_DIR" 2>/dev/null; then
        log_ok "cache cleaned (with sudo)"
    else
        log_warn "could not clean cache - run 'sudo rm -rf $CACHE_DIR' manually"
    fi
}

# === build ===
do_build() {
    log_info "=== BUILD PHASE ==="

    scaffold_docker
    scaffold_dirs
    scaffold_services
    download_fabric
    seed_configs
    scaffold_example_mods
    compile_mods
    download_mods
    download_playit
    assemble_data

    # cleanup if requested
    if [[ "$CLEANUP_CACHE" == true ]]; then
        cleanup_cache
    fi

    # validate
    [[ -f "$DATA_DIR/server.jar" ]] || { log_error "missing server.jar"; exit 1; }
    [[ -f "$DATA_DIR/eula.txt" ]] || { log_error "missing eula.txt"; exit 1; }

    mod_count=$(find "$DATA_DIR/mods" -name "*.jar" 2>/dev/null | wc -l)

    echo ""
    log_ok "build complete: fabric $MINECRAFT_VERSION (loader $FABRIC_LOADER_VERSION), $mod_count mod(s)"
    echo ""

    # playit instructions
    if [[ -f "$SCRIPT_DIR/tools/playit" ]]; then
        echo -e "${BLUE}playit.gg agent available at: tools/playit${NC}"
        echo -e "${BLUE}run './tools/playit' to create a tunnel${NC}"
        echo ""
    fi
}

# === start server via docker ===
do_start() {
    log_info "=== START PHASE ==="

    # build server image
    log_info "building server image..."
    docker build -q -t fabric-server -f "$DOCKER_DIR/Dockerfile.server" "$DOCKER_DIR" > /dev/null
    
    # load env
    ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/env/dev.env}"
    JAVA_OPTS="-Xms1G -Xmx2G"
    if [[ -f "$ENV_FILE" ]]; then
        log_info "loading $ENV_FILE"
        set -a
        # shellcheck disable=SC1090
        source "$ENV_FILE"
        set +a
    fi
    
    log_info "starting server (JAVA_OPTS: $JAVA_OPTS)"
    log_info "java edition:    localhost:25565"
    log_info "bedrock edition: localhost:19132"
    echo ""
    
    # run with docker-compose for proper signal handling
    cd "$DOCKER_DIR"
    JAVA_OPTS="$JAVA_OPTS" docker compose up --build
}

# === main ===
check_docker

if [[ "$FORCE_BUILD" == true ]] || needs_build; then
    if needs_build && [[ "$FORCE_BUILD" == false ]]; then
        log_info "changes detected, rebuilding..."
    fi
    do_build
else
    log_ok "data/ up to date, skipping build"
fi

if [[ "$BUILD_ONLY" == false ]]; then
    do_start
fi
