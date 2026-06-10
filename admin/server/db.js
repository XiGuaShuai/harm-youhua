// MySQL 接入:众包上报 / 共识数据用(配置仍走 data/config.json 文件,不进库)。
// 连接池 + 启动重试(等 MySQL 容器就绪)+ 幂等建表。
import mysql from 'mysql2/promise';

const DB_HOST = process.env.DB_HOST || 'mysql';
const DB_PORT = parseInt(process.env.DB_PORT || '3306', 10);
const DB_USER = process.env.DB_USER || 'webaccel';
const DB_PASS = process.env.DB_PASS || '';
const DB_NAME = process.env.DB_NAME || 'webaccel';

let pool = null;
let ready = false;

export function getPool() {
  return pool;
}

export function dbReady() {
  return ready;
}

// 建表:一人一票(唯一键用 url 的 hash,避开 MySQL 索引长度上限);完整 URL 另存 TEXT。
async function ensureSchema() {
  await pool.query(`
    CREATE TABLE IF NOT EXISTS votes (
      app_id       VARCHAR(64)  NOT NULL,
      url_hash     CHAR(64)     NOT NULL,
      anon_id      VARCHAR(64)  NOT NULL,
      content_hash CHAR(64)     NOT NULL,
      url          TEXT         NOT NULL,
      mime         VARCHAR(128) DEFAULT NULL,
      size         INT          DEFAULT NULL,
      updated_at   BIGINT       NOT NULL,
      PRIMARY KEY (app_id, url_hash, anon_id),
      KEY idx_consensus (app_id, url_hash, content_hash)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
  `);
}

// 后台异步初始化:不阻塞服务启动(配置接口走文件,不依赖 DB);DB 起来前不断重试。
export async function initDb() {
  for (let attempt = 1; attempt <= 60; attempt++) {
    try {
      pool = mysql.createPool({
        host: DB_HOST, port: DB_PORT, user: DB_USER, password: DB_PASS, database: DB_NAME,
        waitForConnections: true, connectionLimit: 10, charset: 'utf8mb4', enableKeepAlive: true
      });
      await pool.query('SELECT 1');
      await ensureSchema();
      ready = true;
      console.log(`[db] MySQL connected (${DB_HOST}:${DB_PORT}/${DB_NAME}), schema ready`);
      return;
    } catch (e) {
      ready = false;
      try { if (pool) await pool.end(); } catch {}
      pool = null;
      console.warn(`[db] not ready (attempt ${attempt}): ${e.code || e.message}; retry in 2s`);
      await new Promise((r) => setTimeout(r, 2000));
    }
  }
  console.error('[db] gave up connecting to MySQL after retries');
}
