import base64
import binascii
from datetime import datetime, timezone
import ipaddress
from typing import Self
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator


class CommandEventIn(BaseModel):
    model_config = ConfigDict(extra="forbid")

    id: UUID
    session_id: UUID
    sequence: int = Field(ge=1)
    hostname: str = Field(min_length=1, max_length=255)
    host_ip: str
    shell: str = Field(min_length=1, max_length=32)
    command: str | None = None
    output: str | None = None
    command_b64: str | None = None
    output_b64: str | None = None
    started_at: datetime
    ended_at: datetime
    exit_code: int | None = None
    duration_ms: int = Field(ge=0)
    truncated: bool = False

    @field_validator("host_ip")
    @classmethod
    def validate_ip(cls, value: str) -> str:
        return str(ipaddress.ip_address(value))

    @field_validator("command_b64", "output_b64")
    @classmethod
    def validate_base64_size(cls, value: str | None) -> str | None:
        if value is not None and len(value) > 1_500_000:
            raise ValueError("encoded payload is too large")
        return value

    @model_validator(mode="after")
    def validate_payloads(self) -> Self:
        if (self.command is None) == (self.command_b64 is None):
            raise ValueError("provide exactly one of command or command_b64")
        if (self.output is None) == (self.output_b64 is None):
            raise ValueError("provide exactly one of output or output_b64")
        return self

    @staticmethod
    def _decode(value: str) -> str:
        try:
            raw = base64.b64decode(value, validate=True)
        except (ValueError, binascii.Error) as exc:
            raise ValueError("invalid base64 payload") from exc
        return raw.decode("utf-8", errors="replace")

    def payloads(self) -> tuple[str, str]:
        command = self.command if self.command is not None else self._decode(self.command_b64 or "")
        output = self.output if self.output is not None else self._decode(self.output_b64 or "")
        return command, output

    def timestamps(self) -> tuple[str, str]:
        def normalize(value: datetime) -> str:
            if value.tzinfo is None:
                value = value.replace(tzinfo=timezone.utc)
            return value.astimezone(timezone.utc).isoformat()

        return normalize(self.started_at), normalize(self.ended_at)


class CommandBatchIn(BaseModel):
    events: list[CommandEventIn] = Field(min_length=1, max_length=50)


class TeamImportIn(BaseModel):
    content: str = Field(max_length=1_000_000)


class TeamMappingIn(BaseModel):
    cidr: str = Field(min_length=1, max_length=64)
    team: str = Field(min_length=1, max_length=100)

    @field_validator("cidr")
    @classmethod
    def validate_cidr(cls, value: str) -> str:
        return str(ipaddress.ip_network(value.strip(), strict=False))

    @field_validator("team")
    @classmethod
    def validate_team(cls, value: str) -> str:
        value = value.strip()
        if not value:
            raise ValueError("team name is empty")
        return value


class BulkTeamMappingIn(BaseModel):
    cidr: str = Field(min_length=1, max_length=64)
    teams: int = Field(ge=1, le=100)

    @field_validator("cidr")
    @classmethod
    def validate_cidr(cls, value: str) -> str:
        network = ipaddress.ip_network(value.strip(), strict=False)
        if network.version != 4 or network.prefixlen != 24:
            raise ValueError("bulk generation requires an IPv4 /24 range")
        return str(network)
