// public/js/api.js — AdvoHQ API client
// Include this in your HTML pages: <script src="/js/api.js"></script>

const API_BASE = window.location.origin + '/api';

class AdvoHQApi {
  constructor() {
    this._token = localStorage.getItem('advohq_token');
  }

  // ── Auth ───────────────────────────────────────────────────────────────────
  get isLoggedIn() { return !!this._token; }

  setToken(token) {
    this._token = token;
    localStorage.setItem('advohq_token', token);
  }

  clearToken() {
    this._token = null;
    localStorage.removeItem('advohq_token');
    localStorage.removeItem('advohq_user');
  }

  // ── Core fetch wrapper ─────────────────────────────────────────────────────
  async _fetch(path, options = {}) {
    const headers = { 'Content-Type': 'application/json', ...(options.headers || {}) };
    if (this._token) headers['Authorization'] = `Bearer ${this._token}`;

    const res = await fetch(`${API_BASE}${path}`, {
      ...options,
      headers,
      body: options.body ? JSON.stringify(options.body) : undefined,
    });

    const data = await res.json();
    if (!res.ok) throw Object.assign(new Error(data.error || 'Request failed'), { status: res.status, data });
    return data.data;
  }

  // ── Auth endpoints ─────────────────────────────────────────────────────────
  async login(username, password) {
    const result = await this._fetch('/auth/login', { method: 'POST', body: { username, password } });
    this.setToken(result.token);
    localStorage.setItem('advohq_user', JSON.stringify(result.user));
    return result;
  }

  async register(payload) {
    const result = await this._fetch('/auth/register', { method: 'POST', body: payload });
    this.setToken(result.token);
    localStorage.setItem('advohq_user', JSON.stringify(result.user));
    return result;
  }

  async me() { return this._fetch('/auth/me'); }

  logout() {
    this.clearToken();
    window.location.href = '/login.html';
  }

  // ── Dashboard ──────────────────────────────────────────────────────────────
  async getDashboard() { return this._fetch('/dashboard'); }

  // ── Cases ──────────────────────────────────────────────────────────────────
  async getCases(params = {}) {
    const qs = new URLSearchParams(params).toString();
    return this._fetch(`/cases${qs ? '?' + qs : ''}`);
  }

  async getCase(id) { return this._fetch(`/cases/${id}`); }

  async createCase(payload) {
    return this._fetch('/cases', { method: 'POST', body: payload });
  }

  async updateCase(id, payload) {
    return this._fetch(`/cases/${id}`, { method: 'PATCH', body: payload });
  }

  async archiveCase(id) {
    return this._fetch(`/cases/${id}`, { method: 'DELETE' });
  }

  // ── Files ──────────────────────────────────────────────────────────────────
  async getFiles(case_id) { return this._fetch(`/files?case_id=${case_id}`); }

  /**
   * Upload a file to S3 via pre-signed URL.
   * @param {string} caseId
   * @param {File} file  Browser File object
   * @param {object} meta  { file_type, description }
   */
  async uploadFile(caseId, file, meta = {}) {
    // Step 1: Get pre-signed URL from our API
    const { file: record, uploadUrl } = await this._fetch('/files', {
      method: 'POST',
      body: {
        case_id:    caseId,
        filename:   file.name,
        mime_type:  file.type || 'application/octet-stream',
        size_bytes: file.size,
        ...meta,
      },
    });

    // Step 2: Upload directly to S3 (no auth header — pre-signed URL handles auth)
    const s3Res = await fetch(uploadUrl, {
      method:  'PUT',
      headers: { 'Content-Type': file.type || 'application/octet-stream' },
      body:    file,
    });
    if (!s3Res.ok) throw new Error('S3 upload failed');

    return record;
  }

  async getFileDownloadUrl(fileId) { return this._fetch(`/files/${fileId}`); }

  async deleteFile(fileId) {
    return this._fetch(`/files/${fileId}`, { method: 'DELETE' });
  }

  // ── Schedule ───────────────────────────────────────────────────────────────
  async getEvents(params = {}) {
    const qs = new URLSearchParams(params).toString();
    return this._fetch(`/schedule${qs ? '?' + qs : ''}`);
  }

  async createEvent(payload) {
    return this._fetch('/schedule', { method: 'POST', body: payload });
  }

  async updateEvent(id, payload) {
    return this._fetch(`/schedule/${id}`, { method: 'PATCH', body: payload });
  }

  async deleteEvent(id) {
    return this._fetch(`/schedule/${id}`, { method: 'DELETE' });
  }

  // ── Users ──────────────────────────────────────────────────────────────────
  async getUser(id) { return this._fetch(`/users/${id}`); }

  async updateUser(id, payload) {
    return this._fetch(`/users/${id}`, { method: 'PATCH', body: payload });
  }

  // ── Helpers ────────────────────────────────────────────────────────────────
  get currentUser() {
    try { return JSON.parse(localStorage.getItem('advohq_user')); }
    catch { return null; }
  }

  requireAuth() {
    if (!this.isLoggedIn) {
      window.location.href = '/login2.html';
      return false;
    }
    return true;
  }
}

// Singleton instance
window.api = new AdvoHQApi();
