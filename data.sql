-- Sokoban data storage schema
-- Target: SQLite 3.x (portable SQL with strict relational constraints)

PRAGMA foreign_keys = ON;

BEGIN TRANSACTION;

-- ------------------------------------------------------------
-- Core reference tables
-- ------------------------------------------------------------

CREATE TABLE IF NOT EXISTS users (
    user_id          INTEGER PRIMARY KEY,
    username         TEXT NOT NULL UNIQUE,
    display_name     TEXT,
    email            TEXT UNIQUE,
    created_at       TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at       TEXT NOT NULL DEFAULT (datetime('now')),
    is_active        INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0,1))
);

CREATE TABLE IF NOT EXISTS source_references (
    source_id        INTEGER PRIMARY KEY,
    source_name      TEXT NOT NULL,
    source_url       TEXT,
    license_name     TEXT,
    citation_text    TEXT,
    UNIQUE (source_name, source_url)
);

CREATE TABLE IF NOT EXISTS map_packs (
    pack_id          INTEGER PRIMARY KEY,
    pack_slug        TEXT NOT NULL UNIQUE,
    pack_name        TEXT NOT NULL,
    description      TEXT,
    source_id        INTEGER REFERENCES source_references(source_id) ON DELETE SET NULL,
    created_by       INTEGER REFERENCES users(user_id) ON DELETE SET NULL,
    created_at       TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at       TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS maps (
    map_id               INTEGER PRIMARY KEY,
    pack_id              INTEGER REFERENCES map_packs(pack_id) ON DELETE SET NULL,
    map_slug             TEXT NOT NULL,
    map_name             TEXT NOT NULL,
    pack_order           INTEGER,
    canonical_version_id INTEGER,
    difficulty_rating    REAL CHECK (difficulty_rating BETWEEN 0.0 AND 10.0),
    created_by           INTEGER REFERENCES users(user_id) ON DELETE SET NULL,
    created_at           TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at           TEXT NOT NULL DEFAULT (datetime('now')),
    archived_at          TEXT,
    UNIQUE (pack_id, map_slug)
);

-- ------------------------------------------------------------
-- Versioned map content
-- ------------------------------------------------------------

CREATE TABLE IF NOT EXISTS map_versions (
    map_version_id        INTEGER PRIMARY KEY,
    map_id                INTEGER NOT NULL REFERENCES maps(map_id) ON DELETE CASCADE,
    version_number        INTEGER NOT NULL CHECK (version_number >= 1),
    xsb_text              TEXT NOT NULL,
    width                 INTEGER NOT NULL CHECK (width > 0),
    height                INTEGER NOT NULL CHECK (height > 0),
    wall_count            INTEGER NOT NULL CHECK (wall_count >= 0),
    floor_count           INTEGER NOT NULL CHECK (floor_count >= 0),
    goal_count            INTEGER NOT NULL CHECK (goal_count >= 0),
    box_count             INTEGER NOT NULL CHECK (box_count >= 0),
    player_start_row      INTEGER NOT NULL CHECK (player_start_row >= 0),
    player_start_col      INTEGER NOT NULL CHECK (player_start_col >= 0),
    normalized_hash       TEXT NOT NULL,
    parsed_ok             INTEGER NOT NULL DEFAULT 1 CHECK (parsed_ok IN (0,1)),
    parser_error          TEXT,
    is_published          INTEGER NOT NULL DEFAULT 0 CHECK (is_published IN (0,1)),
    created_by            INTEGER REFERENCES users(user_id) ON DELETE SET NULL,
    created_at            TEXT NOT NULL DEFAULT (datetime('now')),
    change_notes          TEXT,
    metadata_json         TEXT,
    CHECK (goal_count = box_count),
    CHECK (parsed_ok = 1 OR parser_error IS NOT NULL),
    UNIQUE (map_id, version_number),
    UNIQUE (normalized_hash)
);

CREATE INDEX IF NOT EXISTS idx_map_versions_map_id ON map_versions(map_id);
CREATE INDEX IF NOT EXISTS idx_map_versions_hash ON map_versions(normalized_hash);
CREATE INDEX IF NOT EXISTS idx_map_versions_published ON map_versions(is_published, map_id);

-- Keep maps.canonical_version_id linked to a known version for the same map.
-- SQLite cannot express cross-table CHECKs, so we enforce in a trigger.
CREATE TRIGGER IF NOT EXISTS trg_maps_canonical_version_valid
BEFORE UPDATE OF canonical_version_id ON maps
FOR EACH ROW
WHEN NEW.canonical_version_id IS NOT NULL
BEGIN
    SELECT
        CASE
            WHEN NOT EXISTS (
                SELECT 1
                FROM map_versions mv
                WHERE mv.map_version_id = NEW.canonical_version_id
                  AND mv.map_id = NEW.map_id
            )
            THEN RAISE(ABORT, 'canonical_version_id must reference a version of the same map')
        END;
END;

-- ------------------------------------------------------------
-- Tile-level normalized representation (optional but powerful)
-- ------------------------------------------------------------

CREATE TABLE IF NOT EXISTS map_tiles (
    map_version_id    INTEGER NOT NULL REFERENCES map_versions(map_version_id) ON DELETE CASCADE,
    row_index         INTEGER NOT NULL CHECK (row_index >= 0),
    col_index         INTEGER NOT NULL CHECK (col_index >= 0),
    tile_kind         TEXT NOT NULL CHECK (tile_kind IN ('wall','floor','goal')),
    has_box           INTEGER NOT NULL DEFAULT 0 CHECK (has_box IN (0,1)),
    has_player_start  INTEGER NOT NULL DEFAULT 0 CHECK (has_player_start IN (0,1)),
    PRIMARY KEY (map_version_id, row_index, col_index)
);

CREATE INDEX IF NOT EXISTS idx_map_tiles_kind ON map_tiles(map_version_id, tile_kind);
CREATE INDEX IF NOT EXISTS idx_map_tiles_box ON map_tiles(map_version_id, has_box);

-- ------------------------------------------------------------
-- Taxonomy and tagging
-- ------------------------------------------------------------

CREATE TABLE IF NOT EXISTS tags (
    tag_id           INTEGER PRIMARY KEY,
    tag_name         TEXT NOT NULL UNIQUE,
    description      TEXT
);

CREATE TABLE IF NOT EXISTS map_version_tags (
    map_version_id   INTEGER NOT NULL REFERENCES map_versions(map_version_id) ON DELETE CASCADE,
    tag_id           INTEGER NOT NULL REFERENCES tags(tag_id) ON DELETE CASCADE,
    assigned_by      INTEGER REFERENCES users(user_id) ON DELETE SET NULL,
    assigned_at      TEXT NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (map_version_id, tag_id)
);

CREATE INDEX IF NOT EXISTS idx_map_version_tags_tag ON map_version_tags(tag_id, map_version_id);

-- ------------------------------------------------------------
-- Solver catalog and run telemetry
-- ------------------------------------------------------------

CREATE TABLE IF NOT EXISTS solvers (
    solver_id           INTEGER PRIMARY KEY,
    solver_name         TEXT NOT NULL,
    solver_version      TEXT NOT NULL,
    algorithm_family    TEXT NOT NULL,
    implementation_lang TEXT,
    config_json         TEXT,
    created_at          TEXT NOT NULL DEFAULT (datetime('now')),
    UNIQUE (solver_name, solver_version)
);

CREATE TABLE IF NOT EXISTS solver_runs (
    run_id                     INTEGER PRIMARY KEY,
    map_version_id             INTEGER NOT NULL REFERENCES map_versions(map_version_id) ON DELETE CASCADE,
    solver_id                  INTEGER NOT NULL REFERENCES solvers(solver_id) ON DELETE CASCADE,
    started_by                 INTEGER REFERENCES users(user_id) ON DELETE SET NULL,
    started_at                 TEXT NOT NULL DEFAULT (datetime('now')),
    finished_at                TEXT,
    run_status                 TEXT NOT NULL CHECK (run_status IN ('running','solved','unsolved','timeout','error','cancelled')),
    timeout_ms                 INTEGER CHECK (timeout_ms IS NULL OR timeout_ms > 0),
    node_expansions            INTEGER CHECK (node_expansions IS NULL OR node_expansions >= 0),
    generated_states           INTEGER CHECK (generated_states IS NULL OR generated_states >= 0),
    closed_states              INTEGER CHECK (closed_states IS NULL OR closed_states >= 0),
    reopened_states            INTEGER CHECK (reopened_states IS NULL OR reopened_states >= 0),
    deadlock_pruned_states     INTEGER CHECK (deadlock_pruned_states IS NULL OR deadlock_pruned_states >= 0),
    peak_open_size             INTEGER CHECK (peak_open_size IS NULL OR peak_open_size >= 0),
    elapsed_ms                 INTEGER CHECK (elapsed_ms IS NULL OR elapsed_ms >= 0),
    peak_memory_bytes          INTEGER CHECK (peak_memory_bytes IS NULL OR peak_memory_bytes >= 0),
    machine_fingerprint        TEXT,
    log_text                   TEXT,
    error_message              TEXT,
    CHECK (run_status <> 'error' OR error_message IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS idx_solver_runs_map_solver ON solver_runs(map_version_id, solver_id, started_at DESC);
CREATE INDEX IF NOT EXISTS idx_solver_runs_status ON solver_runs(run_status, started_at DESC);

-- ------------------------------------------------------------
-- Solutions + move-level details
-- ------------------------------------------------------------

CREATE TABLE IF NOT EXISTS solutions (
    solution_id             INTEGER PRIMARY KEY,
    run_id                  INTEGER NOT NULL UNIQUE REFERENCES solver_runs(run_id) ON DELETE CASCADE,
    map_version_id          INTEGER NOT NULL REFERENCES map_versions(map_version_id) ON DELETE CASCADE,
    move_string             TEXT NOT NULL,
    move_count              INTEGER NOT NULL CHECK (move_count >= 0),
    push_count              INTEGER NOT NULL CHECK (push_count >= 0),
    normalized_solution_hash TEXT,
    is_verified             INTEGER NOT NULL DEFAULT 0 CHECK (is_verified IN (0,1)),
    verified_by             INTEGER REFERENCES users(user_id) ON DELETE SET NULL,
    verified_at             TEXT,
    created_at              TEXT NOT NULL DEFAULT (datetime('now')),
    CHECK (verified_at IS NULL OR is_verified = 1)
);

CREATE INDEX IF NOT EXISTS idx_solutions_map_version ON solutions(map_version_id, push_count, move_count);
CREATE INDEX IF NOT EXISTS idx_solutions_hash ON solutions(normalized_solution_hash);

CREATE TABLE IF NOT EXISTS solution_steps (
    solution_id             INTEGER NOT NULL REFERENCES solutions(solution_id) ON DELETE CASCADE,
    step_number             INTEGER NOT NULL CHECK (step_number >= 1),
    action_type             TEXT NOT NULL CHECK (action_type IN ('walk','push')),
    action_char             TEXT NOT NULL CHECK (action_char IN ('u','d','l','r','U','D','L','R')),
    player_row_before       INTEGER,
    player_col_before       INTEGER,
    player_row_after        INTEGER,
    player_col_after        INTEGER,
    box_row_before          INTEGER,
    box_col_before          INTEGER,
    box_row_after           INTEGER,
    box_col_after           INTEGER,
    PRIMARY KEY (solution_id, step_number)
);

CREATE INDEX IF NOT EXISTS idx_solution_steps_type ON solution_steps(solution_id, action_type, step_number);

-- ------------------------------------------------------------
-- Validation events and audit trail
-- ------------------------------------------------------------

CREATE TABLE IF NOT EXISTS validation_events (
    validation_id            INTEGER PRIMARY KEY,
    solution_id              INTEGER NOT NULL REFERENCES solutions(solution_id) ON DELETE CASCADE,
    validator_name           TEXT NOT NULL,
    validator_version        TEXT,
    validated_at             TEXT NOT NULL DEFAULT (datetime('now')),
    is_valid                 INTEGER NOT NULL CHECK (is_valid IN (0,1)),
    failure_step_number      INTEGER,
    failure_reason           TEXT,
    details_json             TEXT
);

CREATE INDEX IF NOT EXISTS idx_validation_solution ON validation_events(solution_id, validated_at DESC);

CREATE TABLE IF NOT EXISTS audit_log (
    audit_id                 INTEGER PRIMARY KEY,
    actor_user_id            INTEGER REFERENCES users(user_id) ON DELETE SET NULL,
    entity_type              TEXT NOT NULL,
    entity_id                INTEGER NOT NULL,
    operation                TEXT NOT NULL CHECK (operation IN ('insert','update','delete','publish','verify','tag')),
    changed_at               TEXT NOT NULL DEFAULT (datetime('now')),
    old_data_json            TEXT,
    new_data_json            TEXT,
    note                     TEXT
);

CREATE INDEX IF NOT EXISTS idx_audit_entity ON audit_log(entity_type, entity_id, changed_at DESC);

-- ------------------------------------------------------------
-- Analytical views
-- ------------------------------------------------------------

CREATE VIEW IF NOT EXISTS v_best_solutions_per_map AS
SELECT
    s.map_version_id,
    MIN(s.push_count) AS best_push_count,
    MIN(CASE
        WHEN s.push_count = (
            SELECT MIN(s2.push_count)
            FROM solutions s2
            WHERE s2.map_version_id = s.map_version_id
        )
        THEN s.move_count
        ELSE NULL
    END) AS best_move_count_among_best_push
FROM solutions s
GROUP BY s.map_version_id;

CREATE VIEW IF NOT EXISTS v_solver_success_rates AS
SELECT
    sr.solver_id,
    so.solver_name,
    so.solver_version,
    COUNT(*) AS total_runs,
    SUM(CASE WHEN sr.run_status = 'solved' THEN 1 ELSE 0 END) AS solved_runs,
    ROUND(
        100.0 * SUM(CASE WHEN sr.run_status = 'solved' THEN 1 ELSE 0 END)
        / NULLIF(COUNT(*), 0),
        2
    ) AS success_rate_pct,
    AVG(sr.elapsed_ms) AS avg_elapsed_ms
FROM solver_runs sr
JOIN solvers so ON so.solver_id = sr.solver_id
GROUP BY sr.solver_id, so.solver_name, so.solver_version;

COMMIT;
