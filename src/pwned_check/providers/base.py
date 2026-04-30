"""Provider abstraction. Future offline sources implement this."""
from abc import ABC, abstractmethod


class PwnedProvider(ABC):
    @abstractmethod
    def lookup(self, prefix: str, suffix: str) -> int:
        """Return pwn count for the SHA-1 prefix/suffix, or 0 if not found.

        May raise NetworkError or ProviderError on failure.
        """
        raise NotImplementedError


class ProviderError(Exception):
    pass


class NetworkError(ProviderError):
    pass
