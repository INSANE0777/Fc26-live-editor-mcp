#!/usr/bin/env python3
"""Core library for reading/writing FC 26 FBCHUNKS/T3DB squad files."""

import struct
import xml.etree.ElementTree as ET
from pathlib import Path
from copy import deepcopy

DB_HEADER = b"\x44\x42\x00\x08\x00\x00\x00\x00"
FBCHUNKS = b"\x46\x42\x43\x48\x55\x4e\x4b\x53\x01\x00"


def load_meta(path):
    tree = ET.parse(path)
    root = tree.getroot()
    table_names = {}
    field_names = {}
    field_range = {}
    field_depth = {}
    field_type = {}
    for table in root.findall("./table"):
        t_name = table.get("name")
        t_short = table.get("shortname")
        table_names[t_short] = t_name
        for field in table.findall("./fields/field"):
            f_name = field.get("name")
            f_short = field.get("shortname")
            f_type = field.get("type")
            f_range = field.get("rangelow", "0")
            f_depth = field.get("depth", "0")
            field_names[f_short] = f_name
            field_type[f_short] = f_type
            field_depth[f_short] = int(f_depth)
            if f_type == "DBOFIELDTYPE_INTEGER":
                field_range[t_name + f_name] = int(f_range)
            else:
                field_range[t_name + f_name] = 0
    return table_names, field_names, field_range, field_depth, field_type


def read_nullbyte_str(data, pos, length):
    end = data.find(b"\x00", pos)
    if end < 0 or end > pos + length:
        end = pos + length
    return data[pos:end].decode("utf-8", errors="ignore")


def read_bits(data, pos, bit_offset, bit_depth):
    byte_off = pos + (bit_offset >> 3)
    start_bit = bit_offset & 7
    value = 0
    bits_read = 0
    while bits_read < bit_depth:
        if byte_off >= len(data):
            break
        b = data[byte_off]
        available = 8 - start_bit
        to_read = min(available, bit_depth - bits_read)
        mask = (1 << to_read) - 1
        value |= ((b >> start_bit) & mask) << bits_read
        bits_read += to_read
        start_bit = 0
        byte_off += 1
    return value


def write_bits(data, pos, bit_offset, bit_depth, value):
    value -= 0  # caller passes raw value without range adjustment
    byte_off = pos + (bit_offset >> 3)
    start_bit = bit_offset & 7
    bits_written = 0
    while bits_written < bit_depth:
        if byte_off >= len(data):
            break
        available = 8 - start_bit
        to_write = min(available, bit_depth - bits_written)
        mask = (1 << to_write) - 1
        bit_chunk = (value >> bits_written) & mask
        data[byte_off] &= ~(mask << start_bit)
        data[byte_off] |= bit_chunk << start_bit
        bits_written += to_write
        start_bit = 0
        byte_off += 1


class SquadFile:
    def __init__(self, path, meta_path):
        self.path = Path(path)
        self.meta_path = Path(meta_path)
        self.table_names, self.field_names, self.field_range, self.field_depth, self.field_type = load_meta(meta_path)
        self.raw = bytearray(self.path.read_bytes())
        self.db_offset = self.raw.find(DB_HEADER)
        if self.db_offset < 0:
            raise ValueError("T3DB header not found in squad file")
        self.db_size = struct.unpack_from("<I", self.raw, self.db_offset + 8)[0]
        self.db_data = self.raw[self.db_offset:self.db_offset + self.db_size]
        self.tables_meta = self._read_table_index()
        self._records = {}
        self._table_fields = {}
        self._dirty = set()

    def _read_table_index(self):
        tc = struct.unpack_from("<I", self.db_data, 16)[0]
        off = 24
        meta = []
        for _ in range(tc):
            short = self.db_data[off:off+4].decode("latin-1", errors="replace")
            offset = struct.unpack_from("<I", self.db_data, off+4)[0]
            name = self.table_names.get(short)
            meta.append({"short": short, "offset": offset, "name": name})
            off += 8
        off += 4
        self._tables_start = off
        return meta

    def _parse_table(self, table_name):
        if table_name in self._records:
            return self._records[table_name], self._table_fields[table_name]

        entry = next((m for m in self.tables_meta if m["name"] == table_name), None)
        if entry is None:
            raise KeyError(f"Table {table_name} not found")

        pos = self._tables_start + entry["offset"]
        pos += 4  # skip
        record_size = struct.unpack_from("<I", self.db_data, pos)[0]
        pos += 4
        pos += 10  # skip
        valid_records = struct.unpack_from("<H", self.db_data, pos)[0]
        pos += 2
        pos += 4  # skip
        fields_count = self.db_data[pos]
        pos += 1
        pos += 11  # skip

        fields = []
        for _ in range(fields_count):
            f_type = struct.unpack_from("<I", self.db_data, pos)[0]
            f_bit_offset = struct.unpack_from("<I", self.db_data, pos+4)[0]
            f_short = self.db_data[pos+8:pos+12].decode("latin-1", errors="replace")
            f_bit_depth = struct.unpack_from("<I", self.db_data, pos+12)[0]
            pos += 16
            f_name = self.field_names.get(f_short, f_short)
            range_low = self.field_range.get(table_name + f_name, 0)
            fields.append({
                "type": f_type,
                "bit_offset": f_bit_offset,
                "short": f_short,
                "name": f_name,
                "bit_depth": f_bit_depth,
                "range_low": range_low,
            })
        fields.sort(key=lambda f: f["bit_offset"])

        records = []
        data_start = pos
        for rec_idx in range(valid_records):
            rec_pos = data_start + rec_idx * record_size
            record = {"__rec_pos": rec_pos, "__record_size": record_size}
            for fld in fields:
                f_type = fld["type"]
                f_name = fld["name"]
                if f_type == 0:  # string
                    byte_off = rec_pos + (fld["bit_offset"] >> 3)
                    value = read_nullbyte_str(self.db_data, byte_off, fld["bit_depth"] >> 3)
                elif f_type == 3:  # int
                    value = read_bits(self.db_data, rec_pos, fld["bit_offset"], fld["bit_depth"])
                    value += fld["range_low"]
                elif f_type == 4:  # float
                    byte_off = rec_pos + (fld["bit_offset"] >> 3)
                    value = struct.unpack_from("<f", self.db_data, byte_off)[0]
                else:
                    value = None
                record[f_name] = value
            records.append(record)

        self._records[table_name] = records
        self._table_fields[table_name] = fields
        return records, fields

    def get_table(self, table_name):
        records, _ = self._parse_table(table_name)
        # Return shallow copies without internal markers
        return [{k: v for k, v in r.items() if not k.startswith("__")} for r in records]

    def update_field(self, table_name, rec_idx, field_name, new_value):
        records, fields = self._parse_table(table_name)
        record = records[rec_idx]
        rec_pos = record["__rec_pos"]
        fld = next((f for f in fields if f["name"] == field_name), None)
        if fld is None:
            raise KeyError(f"Field {field_name} not found in {table_name}")

        if fld["type"] == 3:  # int
            write_bits(self.db_data, rec_pos, fld["bit_offset"], fld["bit_depth"], new_value - fld["range_low"])
            record[field_name] = new_value
            self._dirty.add(table_name)
        else:
            raise NotImplementedError("Only integer fields can be updated currently")

    def save(self, output_path=None):
        """Write modified db_data back into FBCHUNKS wrapper. CRC is zeroed."""
        if output_path is None:
            output_path = self.path
        # Replace the DB section in raw
        self.raw[self.db_offset:self.db_offset + self.db_size] = self.db_data
        # Zero the CRC in the main header (offset 1126 + len(save_type_squads) + 4?)
        # The main header starts at 1126. SaveType_Squads is at 1126. CRC is 4 bytes after.
        crc_offset = 1126 + len(b"SaveType_Squads\x00") + 4
        # Actually, simpler: zero the 4 bytes after SaveType_Squads in main header
        main_header_start = 1126
        save_type = b"SaveType_Squads\x00"
        crc_pos = main_header_start + len(save_type)
        # The save_squads code writes: save_type, then 4 bytes CRC
        self.raw[crc_pos:crc_pos+4] = b"\x00\x00\x00\x00"
        Path(output_path).write_bytes(self.raw)

    def player_clubs(self):
        players_records, _ = self._parse_table("players")
        teams_records, _ = self._parse_table("teams")
        links_records, _ = self._parse_table("teamplayerlinks")
        dc_records, _ = self._parse_table("dcplayernames")

        # dcplayernames field names may vary; inspect first record
        if dc_records:
            sample = dc_records[0]
            name_id_key = next((k for k in sample if "id" in k.lower() and "name" not in k.lower()), None)
            name_key = next((k for k in sample if "name" in k.lower()), None)
        else:
            name_id_key = name_key = None
        names = {}
        if name_id_key and name_key:
            for r in dc_records:
                names[r[name_id_key]] = r[name_key]

        teams = {t.get("teamid"): t for t in teams_records}
        player_map = {p.get("playerid"): p for p in players_records}

        result = []
        for link in links_records:
            pid = link.get("playerid")
            tid = link.get("teamid")
            player = player_map.get(pid, {})
            team = teams.get(tid, {})
            firstname = names.get(player.get("firstnameid", 0), "")
            lastname = names.get(player.get("lastnameid", 0), "")
            common = names.get(player.get("commonnameid", 0), "")
            display = common or f"{firstname} {lastname}".strip()
            result.append({
                "playerid": pid,
                "firstname": firstname,
                "lastname": lastname,
                "commonname": common,
                "displayname": display,
                "teamid": tid,
                "teamname": team.get("teamname", ""),
                "teamabbreviation": team.get("teamabbreviation", ""),
            })
        return result


def find_squad_files(directory="."):
    return [str(p) for p in Path(directory).glob("Squads*") if p.is_file()]
