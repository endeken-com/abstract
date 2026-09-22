import * as S from '@radix-ui/react-switch';

export function Switch({
  checked,
  onCheckedChange,
  disabled,
  label,
}: {
  checked: boolean;
  onCheckedChange: (v: boolean) => void;
  disabled?: boolean;
  label?: string;
}) {
  return (
    <S.Root
      checked={checked}
      onCheckedChange={onCheckedChange}
      disabled={disabled}
      aria-label={label}
      className="relative inline-flex h-[20px] w-[34px] shrink-0 items-center rounded-full transition-colors duration-200 disabled:opacity-40 data-[state=checked]:bg-[var(--bt-accent)] data-[state=unchecked]:bg-[var(--bt-surface-4)]"
      style={{ boxShadow: 'inset 0 1px 2px rgb(0 0 0 / 0.35)' }}
    >
      <S.Thumb
        className="block h-[16px] w-[16px] translate-x-[2px] rounded-full bg-white transition-transform duration-200 ease-[var(--ease-out-soft)] data-[state=checked]:translate-x-[16px]"
        style={{ boxShadow: '0 1px 3px rgb(0 0 0 / 0.45)' }}
      />
    </S.Root>
  );
}
