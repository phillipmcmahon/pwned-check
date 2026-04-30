"""Provider abstraction. Any future offline/local source implements this."""
from abc import ABC, abstractmethod


class PwnedProvider(ABC):
    @abstractmethod
    def lookup(self, prefix: str, suffix: str) -> int:
        """Return the pwn count for the given SHA-1 prefix/suffix, or 0 if not found.

        May raise NetworkError or ProviderError on failure.
        """
        raise NotImplementedError


class ProviderError(Exception):
    pass


class NetworkError(ProviderError):
    pass
