#!/usr/bin/env python3
"""FC 26 Squad File Editor GUI (tkinter).

Open an FC 26 squad file and do everything in the UI:
- browse / search / edit / delete rows in any of the 78 DB tables
- search players, see their club(s) and loans
- apply transfers (player -> new club)
- terminate loans
- auto-backup + save

Run with:  fc26-mcp-gui  (after pip install)  or  python -m fc26_mcp.gui
"""

import sys
import os
import shutil
import threading
import traceback
from datetime import datetime
from pathlib import Path

import tkinter as tk
from tkinter import ttk, filedialog, messagebox

from fc26_mcp.fifa_squad import SquadFile, detect_save_type, career_overview

FREE_AGENT_TEAM = 111592  # NG - FA

SETTINGS_DIR = Path(os.environ.get("LOCALAPPDATA", "")) / "EA SPORTS FC 26" / "settings"
DEFAULT_META = Path(__file__).parent / "data" / "fifa_ng_db-meta-fc26.xml"


def club_ids(sq):
    """Club team IDs: clubworth != 0, plus the free-agent team."""
    teams = sq.get_table("teams")
    return {t["teamid"] for t in teams if t["clubworth"] != 0} | {FREE_AGENT_TEAM}


class SquadEditorApp(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("FC 26 Squad File Editor")
        self.geometry("1100x700")
        self.sq = None
        self.sq_path = None
        self._players_cache = None
        self._teams_cache = None
        self._dc_cache = None
        self._club_ids_cache = None
        self._pending_save = False

        self._build_ui()
        self.log("Welcome. Open a squad file to begin.")

    # ---------------- UI ----------------
    def _build_ui(self):
        # Top bar
        top = ttk.Frame(self, padding=(8, 6))
        top.pack(fill="x")
        ttk.Button(top, text="Open Squad/Career...", command=self.open_file).pack(side="left")
        ttk.Button(top, text="Save", command=self.save_file).pack(side="left", padx=(6, 0))
        ttk.Button(top, text="Backup", command=self.make_backup).pack(side="left", padx=(6, 0))
        self.path_var = tk.StringVar(value="No file open")
        ttk.Label(top, textvariable=self.path_var, anchor="w").pack(side="left", padx=(10, 0), fill="x", expand=True)
        self.dirty_var = tk.StringVar(value="")
        ttk.Label(top, textvariable=self.dirty_var, foreground="#b45309").pack(side="right")

        # Notebook
        nb = ttk.Notebook(self)
        nb.pack(fill="both", expand=True, padx=8, pady=(0, 8))
        self.tab_transfers = ttk.Frame(nb)
        self.tab_players = ttk.Frame(nb)
        self.tab_tables = ttk.Frame(nb)
        self.tab_log = ttk.Frame(nb)
        nb.add(self.tab_transfers, text="Transfers")
        nb.add(self.tab_players, text="Players")
        nb.add(self.tab_tables, text="Tables")
        nb.add(self.tab_log, text="Log")

        self._build_transfers_tab()
        self._build_players_tab()
        self._build_tables_tab()
        self._build_log_tab()

    # ---------- Transfers tab ----------
    def _build_transfers_tab(self):
        f = self.tab_transfers
        panes = ttk.PanedWindow(f, orient="horizontal")
        panes.pack(fill="both", expand=True, padx=6, pady=6)

        # Left: player search
        left = ttk.Frame(panes)
        panes.add(left, weight=1)
        ttk.Label(left, text="Player search (name or ID):").pack(anchor="w")
        row = ttk.Frame(left)
        row.pack(fill="x")
        self.pl_search = ttk.Entry(row)
        self.pl_search.pack(side="left", fill="x", expand=True)
        self.pl_search.bind("<Return>", lambda e: self.search_players())
        ttk.Button(row, text="Search", command=self.search_players).pack(side="left", padx=(4, 0))
        self.pl_list = tk.Listbox(left, height=16)
        self.pl_list.pack(fill="both", expand=True, pady=(4, 0))
        self.pl_list.bind("<<ListboxSelect>>", self.on_player_selected)
        ttk.Label(left, text="Selected player info:").pack(anchor="w", pady=(6, 0))
        self.pl_info = tk.Text(left, height=7, state="disabled", wrap="word")
        self.pl_info.pack(fill="x")

        # Right: team search + action buttons
        right = ttk.Frame(panes)
        panes.add(right, weight=1)
        ttk.Label(right, text="Team search (name or ID):").pack(anchor="w")
        row2 = ttk.Frame(right)
        row2.pack(fill="x")
        self.tm_search = ttk.Entry(row2)
        self.tm_search.pack(side="left", fill="x", expand=True)
        self.tm_search.bind("<Return>", lambda e: self.search_teams())
        ttk.Button(row2, text="Search", command=self.search_teams).pack(side="left", padx=(4, 0))
        self.tm_list = tk.Listbox(right, height=16)
        self.tm_list.pack(fill="both", expand=True, pady=(4, 0))
        self.tm_list.bind("<<ListboxSelect>>", self.on_team_selected)

        btns = ttk.Frame(right)
        btns.pack(fill="x", pady=(8, 0))
        self.btn_transfer = ttk.Button(btns, text="Transfer player to team", command=self.do_transfer, state="disabled")
        self.btn_transfer.pack(side="left", fill="x", expand=True)
        self.btn_terminate = ttk.Button(btns, text="Terminate loan", command=self.do_terminate_loan, state="disabled")
        self.btn_terminate.pack(side="left", fill="x", expand=True, padx=(6, 0))

        self._selected_player = None
        self._selected_team = None

    # ---------- Players tab ----------
    def _build_players_tab(self):
        f = self.tab_players
        row = ttk.Frame(f, padding=6)
        row.pack(fill="x")
        ttk.Label(row, text="Search name or ID:").pack(side="left")
        self.pv_search = ttk.Entry(row)
        self.pv_search.pack(side="left", fill="x", expand=True, padx=6)
        self.pv_search.bind("<Return>", lambda e: self.search_players_view())
        ttk.Button(row, text="Search", command=self.search_players_view).pack(side="left")
        ttk.Button(row, text="Show all", command=self.search_players_view_all).pack(side="left", padx=(4, 0))

        cols = ("playerid", "name", "team")
        self.pv_tree = ttk.Treeview(f, columns=cols, show="headings", selectmode="browse")
        for c, w in (("playerid", 90), ("name", 220), ("team", 240)):
            self.pv_tree.heading(c, text=c)
            self.pv_tree.column(c, width=w)
        self.pv_tree.pack(fill="both", expand=True, padx=6, pady=(0, 6))
        self.pv_tree.bind("<Double-1>", self.on_player_view_double)

    # ---------- Tables tab ----------
    def _build_tables_tab(self):
        f = self.tab_tables
        row = ttk.Frame(f, padding=6)
        row.pack(fill="x")
        ttk.Label(row, text="Table:").pack(side="left")
        self.tb_combo = ttk.Combobox(row, state="readonly", width=32)
        self.tb_combo.pack(side="left", padx=6)
        self.tb_combo.bind("<<ComboboxSelected>>", lambda e: self.load_table())
        ttk.Label(row, text="Filter:").pack(side="left", padx=(12, 0))
        self.tb_filter = ttk.Entry(row, width=28)
        self.tb_filter.pack(side="left", padx=6)
        self.tb_filter.bind("<Return>", lambda e: self.load_table())
        ttk.Button(row, text="Refresh", command=self.load_table).pack(side="left")
        ttk.Button(row, text="Edit cell", command=self.edit_cell).pack(side="left", padx=(6, 0))
        ttk.Button(row, text="Delete row", command=self.delete_row).pack(side="left", padx=(6, 0))
        self.tb_count = tk.StringVar(value="")
        ttk.Label(row, textvariable=self.tb_count).pack(side="left", padx=(12, 0))

        wrap = ttk.Frame(f)
        wrap.pack(fill="both", expand=True, padx=6, pady=(0, 6))
        self.tb_tree = ttk.Treeview(wrap, show="headings", selectmode="browse")
        vsb = ttk.Scrollbar(wrap, orient="vertical", command=self.tb_tree.yview)
        hsb = ttk.Scrollbar(wrap, orient="horizontal", command=self.tb_tree.xview)
        self.tb_tree.configure(yscrollcommand=vsb.set, xscrollcommand=hsb.set)
        self.tb_tree.grid(row=0, column=0, sticky="nsew")
        vsb.grid(row=0, column=1, sticky="ns")
        hsb.grid(row=1, column=0, sticky="ew")
        wrap.rowconfigure(0, weight=1)
        wrap.columnconfigure(0, weight=1)

    # ---------- Log tab ----------
    def _build_log_tab(self):
        self.log_text = tk.Text(self.tab_log, state="disabled", wrap="word")
        self.log_text.pack(fill="both", expand=True, padx=6, pady=6)

    # ---------------- helpers ----------------
    def log(self, msg):
        self.log_text.config(state="normal")
        self.log_text.insert("end", msg + "\n")
        self.log_text.see("end")
        self.log_text.config(state="disabled")

    def log_err(self, msg):
        self.log("ERROR: " + msg)

    def require_squad(self):
        if self.sq is None:
            messagebox.showinfo("No file", "Open a squad file first.")
            return False
        return True

    def refresh_caches(self):
        if self.sq is None:
            return
        self.log("Building caches...")
        names = {m["name"] for m in self.sq.tables_meta if m["name"]}
        self.is_career = "career_users" in names and "teamplayerlinks" not in names
        try:
            self._teams_cache = {t["teamid"]: t.get("teamname", "") for t in self.sq.get_table("teams")}
        except KeyError:
            self._teams_cache = {}
        try:
            self._dc_cache = {r["nameid"]: r["name"] for r in self.sq.get_table("dcplayernames")}
        except KeyError:
            self._dc_cache = {}
        try:
            self._players_cache = self.sq.get_table("players")
        except KeyError:
            self._players_cache = None
        try:
            self._club_ids_cache = club_ids(self.sq)
        except KeyError:
            self._club_ids_cache = set()
        if self.is_career:
            self.log("Career file: player/team/loan tabs need a squad file; use the Tables tab (33 career tables).")
        else:
            self.log(f"Caches ready: {len(self._players_cache or [])} players, {len(self._teams_cache)} teams")

    def player_name(self, p):
        dc = self._dc_cache or {}
        first = dc.get(p.get("firstnameid", 0), "")
        last = dc.get(p.get("lastnameid", 0), "")
        common = dc.get(p.get("commonnameid", 0), "")
        return common or (first + " " + last).strip() or "?"

    def find_player(self, query):
        """Return list of (playerid, displayname, teamname)."""
        query = query.strip()
        if not query or self._players_cache is None:
            return []
        results = []
        ql = query.lower()
        for p in self._players_cache:
            pid = p.get("playerid", 0)
            if query.isdigit():
                if str(pid) != query:
                    continue
            else:
                name = self.player_name(p)
                if ql not in name.lower():
                    continue
            # find club link
            tid = self._player_club_tid(pid)
            results.append((pid, self.player_name(p), self._teams_cache.get(tid, "") or "(no club)"))
            if len(results) >= 60:
                break
        return results

    def _player_club_tid(self, pid):
        """First club team id for a player (national teams excluded)."""
        links = self.sq.get_table("teamplayerlinks")
        for l in links:
            if l["playerid"] == pid and l["teamid"] in self._club_ids_cache:
                return l["teamid"]
        return None

    def _player_all_links(self, pid):
        """All teamplayerlinks rows for a player: (teamid, teamname, is_club)."""
        out = []
        for l in self.sq.get_table("teamplayerlinks"):
            if l["playerid"] == pid:
                tid = l["teamid"]
                out.append((tid, self._teams_cache.get(tid, "?"), tid in self._club_ids_cache))
        return out

    def _player_loans(self, pid):
        out = []
        for l in self.sq.get_table("playerloans"):
            if l["playerid"] == pid:
                out.append(l)
        return out

    # ---------------- actions ----------------
    def open_file(self):
        start = str(SETTINGS_DIR) if SETTINGS_DIR.exists() else os.getcwd()
        path = filedialog.askopenfilename(
            title="Open FC 26 squad file",
            initialdir=start,
            filetypes=[("Squad files", "*"), ("All files", "*.*")],
        )
        if not path:
            return
        self._open_path(path)

    def _open_path(self, path):
        self.path_var.set("Opening... " + path)
        threading.Thread(target=self._open_worker, args=(path,), daemon=True).start()

    def _open_worker(self, path):
        try:
            sq = SquadFile(path, DEFAULT_META)
            self.sq = sq
            self.sq_path = path
            try:
                self.after(0, self._open_done, path)
            except RuntimeError:
                # mainloop not running (e.g. headless test); complete synchronously
                self._open_done(path)
        except Exception as e:
            msg = f"Open failed: {e}\n{traceback.format_exc()}"
            try:
                self.after(0, self.log_err, msg)
            except RuntimeError:
                print(msg, file=sys.stderr)

    def _open_done(self, path):
        self.refresh_caches()
        self.path_var.set(path + ("    (career save)" if getattr(self, "is_career", False) else ""))
        tables = sorted((m["name"] for m in self.sq.tables_meta if m["name"]), key=str.lower)
        self.tb_combo["values"] = tables
        self.tb_combo.set("career_users" if "career_users" in tables else "teamplayerlinks" if "teamplayerlinks" in tables else (tables[0] if tables else ""))
        self.load_table()
        try:
            ov = career_overview(self.sq)
            user = ov.get("user")
            if user:
                self.log(f"Career: {ov.get('user_display')} | usertype={user.get('usertype')} | clubteamid={user.get('clubteamid')} "
                         f"nationalteamid={user.get('nationalteamid')} leagueid={user.get('leagueid')} wage={user.get('wage')} season={user.get('seasoncount')} "
                         f"contracts={ov.get('contracts')}")
        except Exception:
            pass
        self.log(f"Opened: {path}")

    def save_file(self):
        if not self.require_squad():
            return
        path = self.sq_path
        if path is None:
            path = filedialog.asksaveasfilename(title="Save squad file as", defaultextension="")
            if not path:
                return
        try:
            self.sq.save(path)
            self.sq_path = path
            self.path_var.set(path)
            self.dirty_var.set("")
            self._pending_save = False
            self.log(f"Saved: {path}")
            messagebox.showinfo("Saved", f"Saved to:\n{path}")
        except Exception as e:
            self.log_err(f"Save failed: {e}\n{traceback.format_exc()}")
            messagebox.showerror("Save failed", str(e))

    def make_backup(self):
        if not self.require_squad():
            return
        src = Path(self.sq_path) if self.sq_path else Path(self.sq.path)
        if not src.exists():
            self.log_err(f"Source file missing: {src}")
            return
        backup_dir = Path(os.environ.get("FC26_MCP_DIR", "C:/fc26-mcp"))
        backup_dir.mkdir(parents=True, exist_ok=True)
        stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        dst = backup_dir / f"backup_{src.stem}_{stamp}.bak"
        try:
            shutil.copy2(src, dst)
            self.log(f"Backup created: {dst}")
            messagebox.showinfo("Backup", f"Backup saved to:\n{dst}")
        except Exception as e:
            self.log_err(f"Backup failed: {e}")

    # ---- player search (transfers tab) ----
    def search_players(self):
        if not self.require_squad():
            return
        self.pl_list.delete(0, "end")
        for pid, name, team in self.find_player(self.pl_search.get()):
            self.pl_list.insert("end", f"{pid} | {name} | {team}")
        if not self.pl_list.size():
            self.pl_list.insert("end", "(no matches)")
        self._selected_player = None
        self.btn_transfer.config(state="disabled")
        self.btn_terminate.config(state="disabled")

    def on_player_selected(self, _e):
        sel = self.pl_list.curselection()
        if not sel:
            return
        text = self.pl_list.get(sel[0])
        if not text or text.startswith("("):
            return
        pid = int(text.split("|")[0].strip())
        self._selected_player = pid
        self._refresh_player_info(pid)

    def _refresh_player_info(self, pid):
        self.pl_info.config(state="normal")
        self.pl_info.delete("1.0", "end")
        name = "?"
        for p in (self._players_cache or []):
            if p["playerid"] == pid:
                name = self.player_name(p)
                break
        self.pl_info.insert("end", f"Player: {name} ({pid})\n")
        for tid, tname, is_club in self._player_all_links(pid):
            self.pl_info.insert("end", f"  {'CLUB' if is_club else 'NAT '}: {tname} ({tid})\n")
        for loan in self._player_loans(pid):
            from_name = self._teams_cache.get(loan.get("teamidloanedfrom"), "?")
            self.pl_info.insert("end", f"  LOAN from {from_name} ({loan.get('teamidloanedfrom')}), end={loan.get('loandateend')}\n")
        self.pl_info.config(state="disabled")
        has_club = any(is_club for _, _, is_club in self._player_all_links(pid))
        has_loan = bool(self._player_loans(pid))
        self.btn_transfer.config(state="normal" if has_club and self._selected_team else "disabled")
        self.btn_terminate.config(state="normal" if has_loan else "disabled")

    # ---- team search ----
    def search_teams(self):
        if not self.require_squad():
            return
        q = self.tm_search.get().strip().lower()
        self.tm_list.delete(0, "end")
        n = 0
        for tid, tname in sorted(self._teams_cache.items()):
            if q.isdigit():
                if str(tid) != q:
                    continue
            elif q not in tname.lower():
                continue
            self.tm_list.insert("end", f"{tid} | {tname}")
            n += 1
            if n >= 60:
                break
        if not n:
            self.tm_list.insert("end", "(no matches)")
        self._selected_team = None
        self.btn_transfer.config(state="disabled")

    def on_team_selected(self, _e):
        sel = self.tm_list.curselection()
        if not sel:
            return
        text = self.tm_list.get(sel[0])
        if not text or text.startswith("("):
            return
        self._selected_team = int(text.split("|")[0].strip())
        if self._selected_player is not None:
            self.btn_transfer.config(state="normal")

    # ---- transfer / loan actions ----
    def do_transfer(self):
        if not self.require_squad():
            return
        pid, tid = self._selected_player, self._selected_team
        if pid is None or tid is None:
            messagebox.showinfo("Select", "Pick a player and a team first.")
            return
        try:
            records, _ = self.sq._parse_table("teamplayerlinks")
            matching = [(i, r) for i, r in enumerate(records)
                        if r["playerid"] == pid and r["teamid"] in self._club_ids_cache]
            if not matching:
                messagebox.showinfo("No club link", f"Player {pid} has no club link to transfer.")
                return
            for rec_idx, _r in matching:
                self.sq.update_field("teamplayerlinks", rec_idx, "teamid", tid)
            self._pending_save = True
            self.dirty_var.set("UNSAVED CHANGES")
            name = self._teams_cache.get(tid, "?")
            self.log(f"Transfer OK: player {pid} -> {name} ({tid}) [{len(matching)} link(s) updated]")
            self._refresh_player_info(pid)
        except Exception as e:
            self.log_err(f"Transfer failed: {e}\n{traceback.format_exc()}")

    def do_terminate_loan(self):
        if not self.require_squad():
            return
        pid = self._selected_player
        if pid is None:
            return
        try:
            loans = self.sq.get_table("playerloans")
            idxs = [i for i, l in enumerate(loans) if l["playerid"] == pid]
            if not idxs:
                messagebox.showinfo("No loan", f"Player {pid} has no loan entries.")
                return
            if not messagebox.askyesno("Terminate loan", f"Remove {len(idxs)} loan row(s) for player {pid}?"):
                return
            for idx in sorted(idxs, reverse=True):
                self.sq.delete_record("playerloans", idx)
            self._pending_save = True
            self.dirty_var.set("UNSAVED CHANGES")
            self.log(f"Loan terminated for player {pid}")
            self._refresh_player_info(pid)
        except Exception as e:
            self.log_err(f"Loan terminate failed: {e}\n{traceback.format_exc()}")

    # ---- players tab ----
    def search_players_view(self):
        if not self.require_squad():
            return
        self.pv_tree.delete(*self.pv_tree.get_children())
        for pid, name, team in self.find_player(self.pv_search.get()):
            self.pv_tree.insert("", "end", values=(pid, name, team))

    def search_players_view_all(self):
        if not self.require_squad():
            return
        self.pv_tree.delete(*self.pv_tree.get_children())
        for p in self._players_cache:
            pid = p["playerid"]
            tid = self._player_club_tid(pid)
            self.pv_tree.insert("", "end", values=(pid, self.player_name(p), self._teams_cache.get(tid, "")))
            if len(self.pv_tree.get_children()) >= 500:
                break

    def on_player_view_double(self, _e):
        sel = self.pv_tree.selection()
        if not sel:
            return
        pid = int(self.pv_tree.item(sel[0], "values")[0])
        self._selected_player = pid
        self._refresh_player_info(pid)
        self.tab_transfers.tkraise()

    # ---- tables tab ----
    def load_table(self):
        if not self.require_squad():
            return
        name = self.tb_combo.get()
        if not name:
            return
        try:
            records, fields = self.sq._parse_table(name)
        except Exception as e:
            self.log_err(f"Table {name}: {e}")
            return
        filt = self.tb_filter.get().strip().lower()
        cols = [f["name"] for f in fields]
        self.tb_tree.delete(*self.tb_tree.get_children())
        self.tb_tree["columns"] = cols
        for c in cols:
            self.tb_tree.heading(c, text=c)
            self.tb_tree.column(c, width=90, anchor="w")
        shown = 0
        total_shown = 0
        for rec in records:
            if filt and not any(filt in str(v).lower() for v in rec.values() if v is not None):
                continue
            self.tb_tree.insert("", "end", values=tuple(rec.get(c) for c in cols))
            shown += 1
            total_shown += 1
            if shown >= 300:
                break
        extra = len(records) - total_shown
        self.tb_count.set(f"{len(records)} rows" + (f" | showing {total_shown}" + (f" (+{extra} more)" if extra > 0 else "") if filt else ""))
        self._table_records = records
        self._table_fields = fields

    def edit_cell(self):
        if not self.require_squad() or not hasattr(self, "_table_records"):
            messagebox.showinfo("No table", "Load a table first.")
            return
        sel = self.tb_tree.selection()
        if not sel:
            messagebox.showinfo("Select row", "Select a row first.")
            return
        idx = self.tb_tree.index(sel[0])
        records = self._table_records
        if idx >= len(records):
            return
        rec = records[idx]
        table = self.tb_combo.get()

        dlg = tk.Toplevel(self)
        dlg.title(f"Edit row {idx} in {table}")
        dlg.geometry("420x300")
        ttk.Label(dlg, text="Field:").pack(anchor="w", padx=8, pady=(8, 0))
        fields = [f["name"] for f in self._table_fields if f["type"] == 3]  # ints only (update_field limitation)
        var_field = tk.StringVar()
        combo = ttk.Combobox(dlg, textvariable=var_field, values=fields, state="readonly")
        combo.pack(fill="x", padx=8)
        if fields:
            combo.set(fields[0])

        ttk.Label(dlg, text="Current value:").pack(anchor="w", padx=8, pady=(8, 0))
        cur_var = tk.StringVar()
        ttk.Label(dlg, textvariable=cur_var, foreground="#555").pack(anchor="w", padx=8)
        ttk.Label(dlg, text="New value:").pack(anchor="w", padx=8, pady=(8, 0))
        new_var = tk.StringVar()
        ttk.Entry(dlg, textvariable=new_var).pack(fill="x", padx=8)

        def on_field_change(*_):
            f = var_field.get()
            cur_var.set(str(rec.get(f, "")))

        var_field.trace_add("write", on_field_change)
        on_field_change()

        def do_apply():
            f, v = var_field.get(), new_var.get()
            try:
                v = int(v)
            except ValueError:
                messagebox.showerror("Bad value", "Integer required.", parent=dlg)
                return
            try:
                self.sq.update_field(table, idx, f, v)
                rec[f] = v
                self._pending_save = True
                self.dirty_var.set("UNSAVED CHANGES")
                self.log(f"Updated {table}[{idx}].{f} = {v}")
                dlg.destroy()
                self.load_table()
            except Exception as e:
                messagebox.showerror("Edit failed", str(e), parent=dlg)

        ttk.Button(dlg, text="Apply", command=do_apply).pack(pady=10)

    def delete_row(self):
        if not self.require_squad() or not hasattr(self, "_table_records"):
            messagebox.showinfo("No table", "Load a table first.")
            return
        sel = self.tb_tree.selection()
        if not sel:
            messagebox.showinfo("Select row", "Select a row first.")
            return
        idx = self.tb_tree.index(sel[0])
        table = self.tb_combo.get()
        if not messagebox.askyesno("Delete row", f"Delete row {idx} from {table}?"):
            return
        try:
            self.sq.delete_record(table, idx)
            self._pending_save = True
            self.dirty_var.set("UNSAVED CHANGES")
            self.log(f"Deleted row {idx} from {table}")
            self.load_table()
        except Exception as e:
            self.log_err(f"Delete failed: {e}\n{traceback.format_exc()}")


def main():
    # Optional CLI: pass a squad file path to open directly
    if len(sys.argv) > 1 and os.path.exists(sys.argv[1]):
        app = SquadEditorApp()
        app._open_path(sys.argv[1])
        app.mainloop()
    else:
        app = SquadEditorApp()
        app.mainloop()


if __name__ == "__main__":
    main()
