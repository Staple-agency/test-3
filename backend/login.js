// api/auth/login.js — POST /api/auth/login
require('dotenv').config({ path: '.env.local' });
const bcrypt = require('bcryptjs');
const { query } = require('../../lib/db');
const { signToken } = require('../../lib/auth');
const { cors, ok, fail, allowMethods } = require('../../lib/helpers');

module.exports = async function handler(req, res) {
  if (cors(req, res)) return;
  if (!allowMethods(req, res, ['POST'])) return;

  const { username, password } = req.body || {};
  if (!username || !password) {
    return fail(res, 'Username and password are required', 400);
  }

  // Find user by username or email
  const { rows } = await query(
    `SELECT id, email, username, full_name, role, password_hash, is_active, firm_name, bar_number
     FROM users
     WHERE (username = $1 OR email = $1)
     LIMIT 1`,
    [username.toLowerCase().trim()]
  );

  const user = rows[0];
  if (!user) return fail(res, 'Invalid credentials', 401);
  if (!user.is_active) return fail(res, 'Account is deactivated', 403);

  const valid = await bcrypt.compare(password, user.password_hash);
  if (!valid) return fail(res, 'Invalid credentials', 401);

  // Update last login
  await query('UPDATE users SET last_login_at = NOW() WHERE id = $1', [user.id]);

  // Issue JWT
  const token = signToken({
    sub:       user.id,
    email:     user.email,
    username:  user.username,
    full_name: user.full_name,
    role:      user.role,
  });

  // Audit log
  await query(
    `INSERT INTO audit_log (user_id, action, entity, entity_id, ip_address)
     VALUES ($1, 'auth.login', 'users', $1, $2)`,
    [user.id, req.headers['x-forwarded-for'] || req.socket?.remoteAddress]
  ).catch(() => {}); // non-fatal

  return ok(res, {
    token,
    user: {
      id:        user.id,
      email:     user.email,
      username:  user.username,
      full_name: user.full_name,
      role:      user.role,
      firm_name: user.firm_name,
      bar_number: user.bar_number,
    },
  });
};
